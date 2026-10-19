//! title: Print with std.debug.print
//! norun
//! The shape that older tutorials teach. CI compiles it, thus CI fails if master removes it.

const std = @import("std");

// These four lines have two separate old habits: a `main` with no parameter,
// and output through `std.debug.print`. The two habits still work on current
// master, and each habit is independent of the other.
pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
