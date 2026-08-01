//! title: Reading Past the End
//! norun
//! What `slice[4]` does in a build with safety checks turned on.
//!
//! `//! norun` because it deliberately fails: CI compiles it to prove the code
//! is still valid Zig, and does not execute it. It cannot be a Run button on
//! the page either, since the wasm shipped to readers is a size-optimised
//! build with the check compiled out.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const row = [_]u32{ 10, 20, 30, 40 };
    const slice: []const u32 = &row;

    // `index` is a `var` whose value the compiler cannot fold, so this is not
    // rejected at compile time. In Debug or ReleaseSafe the check runs and the
    // program stops here with "index out of bounds: index 4, len 4".
    var index: usize = 4;
    _ = &index;

    std.debug.print("value: {d}\n", .{slice[index]});
}
