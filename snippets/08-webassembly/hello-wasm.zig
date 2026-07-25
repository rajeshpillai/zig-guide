//! title: You Are Running WebAssembly
//! Prints the target this code was compiled for. When you press Run, the same
//! wasm CI verified is fetched and executed in your browser.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &fw.interface;

    try out.print("cpu arch: {t}\n", .{builtin.cpu.arch});
    try out.print("os tag:   {t}\n", .{builtin.os.tag});
    try out.print("pointer:  {d} bits\n", .{@bitSizeOf(usize)});

    try out.flush();
}
