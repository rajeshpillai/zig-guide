//! title: Hello World
//! Prints to stdout using the `Io` instance handed to `main`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
