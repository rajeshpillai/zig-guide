//! title: A main That Cannot Fail
//! The same greeting with `void` instead of `!void`: the error is handled
//! inside `main`, so nothing is left for `main` to return.

const std = @import("std");

pub fn main(init: std.process.Init) void {
    std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n") catch |err| {
        // Without `!` in the return type, every error must be handled here.
        std.debug.print("could not write the greeting: {t}\n", .{err});
        std.process.exit(1);
    };
}
