//! title: An Index Over the Log
//! A second structure, derived from the first, that you now have to keep in step.

const std = @import("std");
const store = @import("flatdb.zig");

/// Key to byte offset of the most recent record for that key. This is the
/// whole idea of an index: not a copy of the data, a map to where it is.
pub const Index = struct {
    keys: [64][]const u8 = undefined,
    offsets: [64]usize = undefined,
    count: usize = 0,

    fn put(ix: *Index, key: []const u8, offset: usize) !void {
        for (ix.keys[0..ix.count], 0..) |existing, i| {
            if (std.mem.eql(u8, existing, key)) {
                ix.offsets[i] = offset;
                return;
            }
        }
        if (ix.count == ix.keys.len) return error.IndexFull;
        ix.keys[ix.count] = key;
        ix.offsets[ix.count] = offset;
        ix.count += 1;
    }

    pub fn get(ix: Index, key: []const u8) ?usize {
        for (ix.keys[0..ix.count], 0..) |existing, i| {
            if (std.mem.eql(u8, existing, key)) return ix.offsets[i];
        }
        return null;
    }
};

/// Rebuild from the log. The index is *derived*: the log is the truth, and
/// this can always be reconstructed from it. That is why an index can be
/// deleted to save space and why a corrupt one is an inconvenience rather
/// than data loss.
pub fn build(log: []const u8) !Index {
    var ix: Index = .{};
    var offset: usize = 0;

    while (offset < log.len) {
        const end = std.mem.findScalarPos(u8, log, offset, '\n') orelse break;
        const line = log[offset..end];

        var fields = std.mem.splitScalar(u8, line, '|');
        const op = fields.next() orelse break;
        const key = fields.next() orelse break;

        // Tombstones are indexed like anything else. Skipping them would leave
        // the index pointing at an older live record, so a deleted key would
        // read back as present.
        _ = op;
        try ix.put(key, offset);
        offset = end + 1;
    }
    return ix;
}

/// Read one record, starting at a known offset. Nothing before it is touched.
fn readAt(log: []const u8, offset: usize, scratch: []u8) !?[]const u8 {
    const end = std.mem.findScalarPos(u8, log, offset, '\n') orelse log.len;
    var fields = std.mem.splitScalar(u8, log[offset..end], '|');
    const op = fields.next() orelse return null;
    _ = fields.next();
    const raw_value = fields.next() orelse "";
    if (std.mem.eql(u8, op, "del")) return null;
    @memcpy(scratch[0..raw_value.len], raw_value);
    return scratch[0..raw_value.len];
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var file: [4096]u8 = undefined;
    var log: std.Io.Writer = .fixed(&file);

    // Enough records that the difference is visible rather than theoretical.
    var name_buf: [16][8]u8 = undefined;
    var names: [16][]const u8 = undefined;
    for (0..16) |i| {
        names[i] = try std.mem.print(&name_buf[i], "key{d:0>2}", .{i});
        try store.append(&log, .{ .op = .put, .key = names[i], .value = "first" });
    }
    // Every key written again, so the newest record for each sits in the back
    // half of the file. A scan has to reach the end to know it has the latest.
    for (0..16) |i| {
        try store.append(&log, .{ .op = .put, .key = names[i], .value = "second" });
    }
    const written = log.buffered();

    var ix = try build(written);
    try out.print("log is {d} bytes, {d} records, {d} distinct keys\n\n", .{
        written.len,
        32,
        ix.count,
    });

    // Two buffers, not one. Both lookups return slices into whatever they
    // were handed, so sharing a buffer means the second call silently
    // rewrites the first answer and the comparison below compares a value
    // with itself.
    var scan_buf: [64]u8 = undefined;
    var seek_buf: [64]u8 = undefined;
    const target = "key03";

    // A scan reads everything, because the last record for a key could be the
    // last record in the file.
    try out.print("scan for {s}: read {d} bytes\n", .{ target, written.len });
    const scanned = try store.lookup(written, target, &scan_buf);

    const offset = ix.get(target).?;
    const end = std.mem.findScalarPos(u8, written, offset, '\n') orelse written.len;
    const seeked = try readAt(written, offset, &seek_buf);
    try out.print("index for {s}: offset {d}, read {d} bytes\n", .{ target, offset, end - offset });
    try out.print("  both say \"{s}\": {}\n\n", .{
        seeked orelse "",
        std.mem.eql(u8, scanned orelse "", seeked orelse ""),
    });

    try out.print("the index costs {d} entries and one update per write\n", .{ix.count});
    try out.print("and it is derived: delete it and `build` reconstructs it\n", .{});

    try out.flush();
}
