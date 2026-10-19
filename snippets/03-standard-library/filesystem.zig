//! title: Filesystem
//! From 0.16, all filesystem APIs take an `Io`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    var buf_out: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf_out);
    const out = &stdout.interface;

    // `std.fs.cwd()` is now `std.Io.Dir.cwd()`. Each operation that uses
    // the disk takes the io instance explicitly.
    var dir = std.Io.Dir.cwd();

    // Create, write, close.
    const file = try dir.createFile(io, "example.txt", .{});
    defer file.close(io);

    var buf: [128]u8 = undefined;
    var writer = file.writerStreaming(io, &buf);
    try writer.interface.writeAll("written by zig\n");
    try writer.interface.flush();

    // Read the full file again.
    const contents = try dir.readFileAlloc(io, "example.txt", gpa, .limited(1 << 20));
    defer gpa.free(contents);
    std.debug.assert(std.mem.eql(u8, contents, "written by zig\n"));
    try out.print("read back {d} bytes\n", .{contents.len});

    // Walk a directory. The number of entries depends on the contents of
    // the working directory. Thus count only the one file that this program
    // created. A value from the real contents of the directory can be
    // different on your machine and on the build that verified this page.
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

// This program runs in wasm. The two runners give the program an empty
// directory as its working directory. In CI, it is a temporary directory. In
// your browser, it is a directory in memory. Thus `Dir.cwd()` holds only the
// file that this program creates.
