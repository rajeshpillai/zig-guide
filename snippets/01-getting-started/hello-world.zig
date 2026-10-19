//! title: Hello World
//! Prints to stdout through the `Io` instance that `main` receives.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
