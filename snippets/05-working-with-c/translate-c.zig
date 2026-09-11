//! title: Calling Vendored C
//! cinclude: calc.h
//! csource: calc.c
//! The whole shape at once: a header read by translate-c, a `.c` compiled into
//! the binary, and Zig calling across with no binding file in between.

const std = @import("std");

// What the removed `@cImport` builtin used to produce. The header is named by
// the build now, so nothing in this file mentions one.
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // `calc_add` is an ordinary member of the module. Translating the header is
    // what makes the name exist; compiling `calc.c` is what makes it link.
    try out.print("calc_add(2, 3) = {d}\n", .{c.calc_add(2, 3)});
    try out.flush();
}
