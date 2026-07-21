//! title: Filesystem
//! norun
//! All filesystem APIs take an `Io` since 0.16.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    // `std.fs.cwd()` is now `std.Io.Dir.cwd()`, and every operation that
    // touches the disk takes the io instance explicitly.
    var dir = std.Io.Dir.cwd();

    // Create, write, close.
    const file = try dir.createFile(io, "example.txt", .{});
    defer file.close(io);

    var buf: [128]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    try writer.interface.writeAll("written by zig\n");
    try writer.interface.flush();

    // Read the whole thing back.
    const contents = try dir.readFileAlloc(io, "example.txt", gpa, .limited(1 << 20));
    defer gpa.free(contents);
    std.debug.assert(std.mem.eql(u8, contents, "written by zig\n"));

    // Walk a directory.
    var iterable = try dir.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var it = iterable.iterate();
    while (try it.next(io)) |entry| {
        _ = entry.name;
    }

    try dir.deleteFile(io, "example.txt");
}

// Marked `//! norun`: the browser WASI sandbox has no preopened directories,
// so this compiles (proving the API is current) but is not executed.
