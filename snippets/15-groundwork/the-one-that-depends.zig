//! title: The One That Depends on the Build
//! fails
//! Plain `+` on values that overflow, in a build that still has the check.
//!
//! Built `.safe`, where what happens here is defined: the check runs and the
//! program stops. That is why this can carry an expected message at all. In
//! the `.small` build the rest of the site ships, there is no check and no
//! promise about the result, so there would be nothing correct to assert.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // 300 does not fit in a u8. In this build the check runs and stops here.
    // In ReleaseFast or ReleaseSmall there is no check, and the value you
    // would get is not defined. Not "wraps". Undefined.
    const sum = a + b;

    std.debug.print("sum: {d}\n", .{sum});
}
