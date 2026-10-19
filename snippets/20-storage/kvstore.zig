//! title: A Write-Ahead Log
//! Write down what you will do, then do it. Recovery is a replay of the note.

const std = @import("std");

/// Adler-style: two sums, one of the bytes and one of the sums. Thus the
/// order of the bytes is important. The function is hand-written because this
/// track builds the parts that it uses. The necessary property is easy to
/// state: if you change a byte, the number changes.
fn checksum(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// `<checksum>|<op>|<key>|<value>\n`. The checksum is first, so that a reader
/// can read it before the data that it describes. The newline marks the end
/// of a record. Thus a write that stopped in the middle leaves a last line
/// without a newline.
pub fn append(wal: *std.Io.Writer, op: []const u8, key: []const u8, value: []const u8) !void {
    var body: [256]u8 = undefined;
    const payload = try std.mem.print(&body, "{s}|{s}|{s}", .{ op, key, value });
    try wal.print("{d}|{s}\n", .{ checksum(payload), payload });
}

pub const Store = struct {
    keys: [32][]const u8 = undefined,
    values: [32][]const u8 = undefined,
    count: usize = 0,

    fn set(s: *Store, key: []const u8, value: []const u8) !void {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                s.values[i] = value;
                return;
            }
        }
        if (s.count == s.keys.len) return error.Full;
        s.keys[s.count] = key;
        s.values[s.count] = value;
        s.count += 1;
    }

    fn remove(s: *Store, key: []const u8) void {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                s.keys[i] = s.keys[s.count - 1];
                s.values[i] = s.values[s.count - 1];
                s.count -= 1;
                return;
            }
        }
    }

    pub fn get(s: Store, key: []const u8) ?[]const u8 {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return s.values[i];
        }
        return null;
    }
};

pub const Recovery = struct { store: Store, applied: usize, discarded: usize };

/// Build the store again from a replay of the log. Stop at the first record
/// that fails verification. Do not skip the record and continue, because a
/// log is a sequence. A record after a broken record can depend on it.
pub fn replay(wal: []const u8) Recovery {
    var store: Store = .{};
    var applied: usize = 0;
    var offset: usize = 0;
    // The end of the part of the log that is known good. The value moves
    // only after the program verifies *and* applies a record. Thus a record
    // that fails its checksum counts as discarded, and is not silently used.
    var good: usize = 0;

    while (offset < wal.len) {
        // No newline means that the process stopped during a write. All the
        // data before the partial record is intact. The replay ignores the
        // partial record, as if the program never wrote it.
        const end = std.mem.findScalarPos(u8, wal, offset, '\n') orelse break;
        const line = wal[offset..end];
        offset = end + 1;

        const bar = std.mem.findScalar(u8, line, '|') orelse break;
        const declared = std.fmt.parseInt(u32, line[0..bar], 10) catch break;
        const payload = line[bar + 1 ..];
        if (checksum(payload) != declared) break;

        var fields = std.mem.splitScalar(u8, payload, '|');
        const op = fields.next() orelse break;
        const key = fields.next() orelse break;
        const value = fields.next() orelse "";

        if (std.mem.eql(u8, op, "set")) {
            store.set(key, value) catch break;
        } else {
            store.remove(key);
        }
        applied += 1;
        good = offset;
    }

    return .{ .store = store, .applied = applied, .discarded = wal.len - good };
}

fn report(out: *std.Io.Writer, label: []const u8, wal: []const u8) !void {
    const r = replay(wal);
    try out.print("{s}\n", .{label});
    try out.print("  {d} records applied, {d} trailing bytes discarded\n", .{ r.applied, r.discarded });
    for ([_][]const u8{ "a", "b", "c" }) |key| {
        try out.print("  {s} -> {s}\n", .{ key, r.store.get(key) orelse "(absent)" });
    }
    try out.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var file: [1024]u8 = undefined;
    var wal: std.Io.Writer = .fixed(&file);

    try append(&wal, "set", "a", "one");
    try append(&wal, "set", "b", "two");
    try append(&wal, "set", "a", "uno");
    try append(&wal, "set", "c", "three");
    const full = wal.buffered();

    try out.print("the log:\n{s}\n", .{full});
    try report(out, "clean shutdown", full);

    // The power fails during the last write. The bytes that got to the disk
    // are a line with no newline at the end.
    const torn = full[0 .. full.len - 8];
    try report(out, "crash during the last write", torn);

    // A byte changes in the middle of the log. The newline framing cannot
    // see this change, but the checksum can see it.
    var damaged: [1024]u8 = undefined;
    @memcpy(damaged[0..full.len], full);
    // Inside the second record. The third and fourth records are still
    // readable, but the replay refuses them.
    damaged[30] = 'X';
    try report(out, "a byte corrupted in the second record", damaged[0..full.len]);

    try out.flush();
}
