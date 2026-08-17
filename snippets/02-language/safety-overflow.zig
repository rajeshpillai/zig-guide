//! title: Integer Overflow
//! fails
//! `+=` on a value that will not fit is a checked illegal behaviour.
//!
//! Built `.safe` rather than the site-wide `.small`, because in `.small` there
//! is no check and no defined result to show. CI runs it and requires the
//! message in `safety-overflow.expected-error`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var x: u8 = 255;
    _ = &x; // defeat comptime evaluation

    // 256 does not fit in a u8. `+=` is the checked add: in this build the
    // check runs and the program stops here. In ReleaseFast or ReleaseSmall
    // there is no check, and the value is not defined. Not "wraps". Undefined.
    x += 1;

    std.debug.print("never printed: {d}\n", .{x});
}
