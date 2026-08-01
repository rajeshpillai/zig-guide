//! title: A Write-Ahead Log
//! Write down what you are about to do, then do it. Recovery is replaying the note.

const std = @import("std");

/// Adler-style: two running sums, one of the bytes and one of the sums, so
/// the order of the bytes matters. Hand-rolled because this track builds what
/// it uses, and because the property that matters is easy to state: change any
/// byte and the number changes.
fn checksum(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// `<checksum>|<op>|<key>|<value>\n`. The checksum comes first so it can be
/// read before the thing it describes, and the newline is the frame: a torn
/// write leaves a last line without one.
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

/// Rebuild the store by replaying the log, and stop at the first record that
/// does not verify. Stopping rather than skipping is the important half: a
/// log is a sequence, and a record after a broken one may depend on it.
pub fn replay(wal: []const u8) Recovery {
    var store: Store = .{};
    var applied: usize = 0;
    var offset: usize = 0;
    // How far the log is known good. Advanced only after a record has been
    // verified *and* applied, so a record that fails its checksum is counted
    // as discarded rather than silently consumed.
    var good: usize = 0;

    while (offset < wal.len) {
        // No newline means the process died mid-write. Everything before is
        // intact, and this partial record never happened.
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

    // The power goes out part way through the last write. The bytes that
    // reached the disk are a line with no newline on the end.
    const torn = full[0 .. full.len - 8];
    try report(out, "crash during the last write", torn);

    // A byte flips in the middle of the log. The newline framing cannot see
    // this; the checksum can.
    var damaged: [1024]u8 = undefined;
    @memcpy(damaged[0..full.len], full);
    // Inside the second record, so the third and fourth are still perfectly
    // readable and are refused anyway.
    damaged[30] = 'X';
    try report(out, "a byte corrupted in the second record", damaged[0..full.len]);

    try out.flush();
}
