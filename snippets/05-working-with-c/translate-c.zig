//! title: Calling Vendored C
//! cinclude: calc.h
//! csource: calc.c
//! The full shape: translate-c reads a header, the build compiles a `.c` file
//! into the binary, and Zig calls C without a binding file.

const std = @import("std");

// The removed `@cImport` builtin made this module before. Now the build names
// the header. Thus this file does not name a header.
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // `calc_add` is an ordinary member of the module. The translation of the
    // header makes the name. The compiled `calc.c` lets the name link.
    try out.print("calc_add(2, 3) = {d}\n", .{c.calc_add(2, 3)});
    try out.flush();
}
