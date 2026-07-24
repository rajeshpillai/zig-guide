//! title: Compressing with zlib
//! link: z
//! cinclude: zlib.h
//! One-shot compress and decompress through the system zlib.

const std = @import("std");
const c = @import("c");

fn check(rc: c_int) !void {
    if (rc != c.Z_OK) return error.Zlib;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Repetitive data so the win is obvious. (`**` string repeat was removed
    // from the language, so build it in a loop.)
    var input: std.ArrayList(u8) = .empty;
    for (0..32) |_| try input.appendSlice(gpa, "the zig programming language. ");
    const src = input.items;

    // compressBound is the largest the output can be; size the buffer to it.
    var comp_len: c.uLongf = c.compressBound(@intCast(src.len));
    const comp = try gpa.alloc(u8, @intCast(comp_len));
    try check(c.compress2(comp.ptr, &comp_len, src.ptr, @intCast(src.len), 6));

    // Decompress into a buffer the size of the original.
    var back_len: c.uLongf = @intCast(src.len);
    const back = try gpa.alloc(u8, src.len);
    try check(c.uncompress(back.ptr, &back_len, comp.ptr, comp_len));

    // Compressed size is left off stdout on purpose: it varies by zlib version,
    // and every line here has to be reproducible. The relations do not vary.
    try out.print("original:           {d} bytes\n", .{src.len});
    try out.print("compressed smaller: {}\n", .{comp_len < src.len});
    try out.print("roundtrip matches:  {}\n", .{std.mem.eql(u8, src, back[0..@intCast(back_len)])});

    try out.flush();
}
