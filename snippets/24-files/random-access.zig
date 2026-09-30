//! title: Random Access
//! A file of fixed-size records: read record N without reading the ones
//! before it, change one in place, and grow and shrink the file.

const std = @import("std");

const Io = std.Io;

// One record is 16 bytes, little-endian, at offset `index * 16`.
//
//   0  id       u32
//   4  balance  i64   in cents
//   12 active   u8    1 or 0
//   13 unused   3 bytes, always zero
const record_size = 16;

const Account = struct {
    id: u32,
    balance: i64,
    active: bool,

    fn encode(a: Account) [record_size]u8 {
        var bytes: [record_size]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], a.id, .little);
        std.mem.writeInt(i64, bytes[4..12], a.balance, .little);
        bytes[12] = @intFromBool(a.active);
        return bytes;
    }

    fn decode(bytes: *const [record_size]u8) Account {
        return .{
            .id = std.mem.readInt(u32, bytes[0..4], .little),
            .balance = std.mem.readInt(i64, bytes[4..12], .little),
            .active = bytes[12] != 0,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, "accounts.db", .{ .read = true });
    defer file.close(io);

    // 1. Write five records, each at its own offset.
    try out.print("1. five records\n", .{});
    for (0..5) |i| {
        const a: Account = .{ .id = @intCast(100 + i), .balance = @intCast(1000 * (i + 1)), .active = true };
        try writeRecord(io, file, i, a);
    }
    try list(io, file, out, true);

    // 2. Read one record directly.
    try out.print("2. record 3 only\n", .{});
    const a3 = try readRecord(io, file, 3);
    try out.print("   read 16 bytes at offset {d}: id {d}\n", .{ 3 * record_size, a3.id });

    // 3. Change one record in place. Nothing else in the file moves.
    try out.print("3. update record 1\n", .{});
    var a1 = try readRecord(io, file, 1);
    a1.balance -= 750;
    try writeRecord(io, file, 1, a1);
    const updated = try readRecord(io, file, 1);
    try out.print("   record 1 is now id {d}  balance {d}\n", .{ updated.id, updated.balance });
    try list(io, file, out, false);

    // 4. Write past the end. The gap reads back as zero bytes.
    try out.print("4. write record 7\n", .{});
    try writeRecord(io, file, 7, .{ .id = 107, .balance = 99, .active = true });
    try list(io, file, out, true);

    // 5. A reader that seeks, instead of an offset on every call.
    try out.print("5. seek to the last record\n", .{});
    {
        var buf: [record_size]u8 = undefined;
        var reader = file.reader(io, &buf);
        const size = try reader.getSize();
        try reader.seekTo(size - record_size);
        const last = Account.decode(try reader.interface.takeArray(record_size));
        try out.print("   size {d}, seekTo({d}), id {d}\n", .{ size, size - record_size, last.id });
    }

    // 6. Shrink the file to drop the tail.
    try out.print("6. setLength to 5 records\n", .{});
    try file.setLength(io, 5 * record_size);
    try list(io, file, out, false);

    // 7. A length that is not a whole number of records.
    try out.print("7. a torn write\n", .{});
    try file.writePositionalAll(io, "\x69\x00\x00\x00\x00\x00", 5 * record_size);
    try out.print("   file length {d}\n", .{try file.length(io)});
    if (list(io, file, out, false)) |_| {} else |err| try out.print("   {t}\n", .{err});

    try dir.deleteFile(io, "accounts.db");
}

fn writeRecord(io: Io, file: Io.File, index: usize, a: Account) !void {
    const bytes = a.encode();
    try file.writePositionalAll(io, &bytes, index * record_size);
}

fn readRecord(io: Io, file: Io.File, index: usize) !Account {
    var bytes: [record_size]u8 = undefined;
    const n = try file.readPositionalAll(io, &bytes, index * record_size);
    if (n != record_size) return error.NoSuchRecord;
    return Account.decode(&bytes);
}

fn list(io: Io, file: Io.File, out: *Io.Writer, show_records: bool) !void {
    const size = try file.length(io);
    if (size % record_size != 0) return error.PartialRecord;
    const count = std.math.cast(usize, size / record_size) orelse return error.FileTooBig;
    try out.print("   {d} bytes, {d} records\n", .{ size, count });
    if (!show_records) return;
    for (0..count) |i| {
        const a = try readRecord(io, file, i);
        if (a.id == 0) {
            try out.print("     [{d}] empty\n", .{i});
        } else {
            try out.print("     [{d}] id {d}  balance {d}\n", .{ i, a.id, a.balance });
        }
    }
}
