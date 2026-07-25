//! title: A WASI Command
//! A normal program: it does work, writes stdout, and exits with a status.
//! WASI is the interface that gives wasm those OS-shaped abilities.

const std = @import("std");

const document =
    \\zig compiles to wasm
    \\wasm runs in the browser
    \\the browser runs this page
;

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &fw.interface;

    var lines: usize = 0;
    var words: usize = 0;
    var it = std.mem.splitScalar(u8, document, '\n');
    while (it.next()) |line| {
        lines += 1;
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        while (w.next()) |_| words += 1;
    }

    try out.print("lines: {d}\n", .{lines});
    try out.print("words: {d}\n", .{words});
    try out.flush();
}
