//! title: Filesystem
//! native
//! All filesystem APIs take an `Io` since 0.16.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    var buf_out: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf_out);
    const out = &stdout.interface;

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
    try out.print("read back {d} bytes\n", .{contents.len});

    // Walk a directory. The entry count is whatever happens to be in the
    // working directory, so count only the one file this program created:
    // anything derived from the directory's real contents would differ
    // between your machine and the build that verified this page.
    var iterable = try dir.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var it = iterable.iterate();
    var found = false;
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "example.txt")) found = true;
    }
    try out.print("example.txt listed in cwd: {}\n", .{found});

    try dir.deleteFile(io, "example.txt");
    try out.flush();
}

// Marked `//! native`: CI builds this for the host and runs it against a real
// filesystem, so the round trip above is actually checked. It is the browser
// that cannot run it, because the WASI sandbox has no preopened directories.
