//! title: Binary Files
//! A small file format with a header, written field by field and read back
//! with every check a reader of untrusted bytes needs.

const std = @import("std");

const Io = std.Io;

// The format, on paper first. All integers are little-endian.
//
//   header, 10 bytes
//     0  magic    4 bytes  "SCOR"
//     4  version  u16      1
//     6  count    u32      number of records
//
//   record, 9 bytes + name
//     0  id        u32
//     4  score     i32
//     8  name_len  u8
//     9  name      name_len bytes
const magic = "SCOR";
const version: u16 = 1;

const Player = struct {
    id: u32,
    score: i32,
    name: []const u8,
};

const players = [_]Player{
    .{ .id = 7, .score = 1200, .name = "ada" },
    .{ .id = 42, .score = -15, .name = "linus" },
    .{ .id = 300, .score = 0, .name = "grace" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Byte order.
    try out.print("1. the number 0x01020304 as four bytes\n", .{});
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, 0x01020304, endian);
        try out.print("   {t:<7} {x}\n", .{ endian, bytes });
    }

    // 2. Write the file and dump every byte.
    try out.print("2. scores.bin\n", .{});
    try save(io, dir, "scores.bin", &players);
    try hexDump(io, dir, "scores.bin", out);

    // 3. Read it back.
    try out.print("3. read back\n", .{});
    try printFile(io, dir, "scores.bin", out);

    // 4. Three files that are wrong in different ways.
    try out.print("4. bad files\n", .{});
    var good: [64]u8 = undefined;
    const bytes = try dir.readFile(io, "scores.bin", &good);

    try dir.writeFile(io, .{ .sub_path = "photo.png", .data = "\x89PNG\r\n\x1a\n\x00\x00" });
    var newer = bytes[0..10].*;
    std.mem.writeInt(u16, newer[4..6], 2, .little);
    try dir.writeFile(io, .{ .sub_path = "newer.bin", .data = &newer });
    try dir.writeFile(io, .{ .sub_path = "cut.bin", .data = bytes[0 .. bytes.len - 4] });

    for ([_][]const u8{ "photo.png", "newer.bin", "cut.bin" }) |name| {
        try out.print("   {s}: ", .{name});
        if (printFile(io, dir, name, out)) |_| {} else |err| try out.print("{t}\n", .{err});
    }

    for ([_][]const u8{ "scores.bin", "photo.png", "newer.bin", "cut.bin" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn save(io: Io, dir: Io.Dir, name: []const u8, list: []const Player) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u32, @intCast(list.len), .little);

    for (list) |p| {
        try w.writeInt(u32, p.id, .little);
        try w.writeInt(i32, p.score, .little);
        try w.writeByte(@intCast(p.name.len));
        try w.writeAll(p.name);
    }
    try w.flush();
}

const FormatError = error{ NotScoresFile, UnsupportedVersion, Truncated, TooManyRecords, NameTooLong };

/// A record read from disk. The name is copied out of the reader's buffer,
/// because the next read can overwrite that buffer.
const Record = struct {
    id: u32,
    score: i32,
    name_buf: [16]u8,
    name_len: u8,

    fn name(r: *const Record) []const u8 {
        return r.name_buf[0..r.name_len];
    }
};

const max_records = 8;

fn printFile(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [512]u8 = undefined;
    var fr = file.reader(io, &buf);

    var records: [max_records]Record = undefined;
    const n = readRecords(&fr.interface, &records) catch |err| switch (err) {
        // The file ended in the middle of something. For a reader of a
        // format, that is a broken file, not the normal end of input.
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return fr.err.?,
        else => |e| return e,
    };

    // Only now, with the whole file checked, do we act on it.
    for (records[0..n]) |*rec| {
        var num: [12]u8 = undefined;
        const score = try std.mem.print(&num, "{d}", .{rec.score});
        try out.print("   id {d:>3}  score {s:>5}  {s}\n", .{ rec.id, score, rec.name() });
    }
}

fn readRecords(r: *Io.Reader, records: []Record) !usize {
    // Check what the file claims to be before trusting anything after it.
    if (!std.mem.eql(u8, try r.takeArray(4), magic)) return FormatError.NotScoresFile;
    if (try r.takeInt(u16, .little) != version) return FormatError.UnsupportedVersion;

    // `count` comes from the file, so it is untrusted like everything else.
    const count = try r.takeInt(u32, .little);
    if (count > records.len) return FormatError.TooManyRecords;

    for (records[0..count]) |*rec| {
        rec.id = try r.takeInt(u32, .little);
        rec.score = try r.takeInt(i32, .little);
        rec.name_len = try r.takeByte();
        if (rec.name_len > rec.name_buf.len) return FormatError.NameTooLong;
        @memcpy(rec.name_buf[0..rec.name_len], try r.take(rec.name_len));
    }
    return count;
}

fn hexDump(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var buf: [64]u8 = undefined;
    const bytes = try dir.readFile(io, name, &buf);
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        const row = bytes[offset..@min(offset + 16, bytes.len)];
        try out.print("   {x:0>4}  ", .{offset});
        for (row) |b| try out.print("{x:0>2} ", .{b});
        try out.splatByteAll(' ', (16 - row.len) * 3 + 1);
        for (row) |b| try out.writeByte(if (std.ascii.isPrint(b)) b else '.');
        try out.writeByte('\n');
    }
    try out.print("   {d} bytes\n", .{bytes.len});
}
