//! title: Runtime Safety
//! norun
//! Safety checks are on in Debug and ReleaseSafe, off in ReleaseFast/Small.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Zig inserts checks for out-of-bounds access, integer overflow, invalid
    // casts, and more. In a safety-enabled build this panics with
    // "index out of bounds" rather than reading whatever memory follows.
    const array = [_]u8{ 1, 2, 3 };
    var index: usize = 5;
    _ = &index; // defeat comptime evaluation
    const value = array[index];
    std.debug.print("never printed: {d}\n", .{value});
}

// This snippet is marked `//! norun` because it deliberately panics: CI
// compiles it to prove the code is still valid, but does not execute it.
