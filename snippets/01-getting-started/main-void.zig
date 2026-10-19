//! title: A main That Cannot Fail
//! The same greeting with `void` instead of `!void`. `main` handles the
//! error itself, thus nothing remains for `main` to return.

const std = @import("std");

pub fn main(init: std.process.Init) void {
    std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n") catch |err| {
        // If the return type has no `!`, handle each error here.
        std.debug.print("could not write the greeting: {t}\n", .{err});
        std.process.exit(1);
    };
}
