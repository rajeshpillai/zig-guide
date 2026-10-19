//! title: Runtime Safety
//! fails
//! Safety checks are on in Debug and ReleaseSafe, off in ReleaseFast/Small.
//!
//! Built `.safe` rather than the site-wide `.small`, so the check this chapter
//! is about is actually in the artifact the reader runs. CI runs it and
//! requires the message in `runtime-safety.expected-error`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Zig inserts checks for out-of-bounds access, integer overflow, invalid
    // casts, and more. In a build with safety checks, this code panics with
    // "index out of bounds". It does not read the memory after the array.
    const array = [_]u8{ 1, 2, 3 };
    var index: usize = 5;
    _ = &index; // stop comptime evaluation
    const value = array[index];
    std.debug.print("never printed: {d}\n", .{value});
}

// This program panics intentionally. CI runs it and requires it to stop with
// exactly the message that this chapter quotes.
