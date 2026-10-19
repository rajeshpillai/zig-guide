//! title: You Are Running WebAssembly
//! Prints the target of this compiled code. When you press Run, your browser
//! fetches and runs the same wasm that CI verified.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &fw.interface;

    try out.print("cpu arch: {t}\n", .{builtin.target.cpu.arch});
    try out.print("os tag:   {t}\n", .{builtin.target.os.tag});
    try out.print("pointer:  {d} bits\n", .{@bitSizeOf(usize)});

    try out.flush();
}
