//! title: The Older main Signature
//! norun
//! The pre-Io shape, kept compiled so CI fails the day master drops it.

const std = @import("std");

// Every Zig tutorial written before the `Io` changes opens with this. It is
// still accepted on current master. `std.debug.print` writes to stderr and
// needs no `Io`, which is exactly why it survives here and why it is not the
// tool for a program's actual output.
pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
