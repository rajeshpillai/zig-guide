//! title: A File-Backed To-Do Store
//! native
//! Fixed-size records give random access by id: append, read, update in place.

const std = @import("std");

// An extern struct has a fixed, predictable layout, so every record is the same
// number of bytes on disk. That is what makes record N reachable directly at
// offset N * @sizeOf(Record), with no index and no scan.
const Record = extern struct {
    id: u32,
    done: bool,
    len: u8,
    text: [64]u8,
};

fn addTask(io: std.Io, file: std.Io.File, text: []const u8) !u32 {
    const end = try file.length(io);
    const id: u32 = @intCast(end / @sizeOf(Record) + 1);

    var rec: Record = .{ .id = id, .done = false, .len = @intCast(@min(text.len, 64)), .text = @splat(0) };
    @memcpy(rec.text[0..rec.len], text[0..rec.len]);

    // Append by writing at the current end of file.
    try file.writePositionalAll(io, std.mem.asBytes(&rec), end);
    return id;
}

fn toggle(io: std.Io, file: std.Io.File, id: u32) !void {
    const offset = (id - 1) * @sizeOf(Record);

    // Read one record straight from its slot, flip the flag, write it back to
    // the same slot. No rewrite of the whole file.
    var rec: Record = undefined;
    _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
    rec.done = !rec.done;
    try file.writePositionalAll(io, std.mem.asBytes(&rec), offset);
}

fn list(io: std.Io, file: std.Io.File, out: *std.Io.Writer) !void {
    const end = try file.length(io);
    var offset: u64 = 0;
    while (offset < end) : (offset += @sizeOf(Record)) {
        var rec: Record = undefined;
        _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
        try out.print("{d}  [{s}]  {s}\n", .{
            rec.id,
            if (rec.done) "x" else " ",
            rec.text[0..rec.len],
        });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // A fresh database each run (createFile truncates by default), removed at
    // the end so the example leaves nothing behind.
    var dir = std.Io.Dir.cwd();
    const file = try dir.createFile(io, "todo-demo.db", .{ .read = true });
    defer dir.deleteFile(io, "todo-demo.db") catch {};
    defer file.close(io);

    _ = try addTask(io, file, "write the recipe");
    const verify = try addTask(io, file, "verify it");
    _ = try addTask(io, file, "ship it");

    try toggle(io, file, verify); // mark item 2 done

    try out.print("record size: {d} bytes\n\n", .{@sizeOf(Record)});
    try list(io, file, out);

    try out.flush();
}
