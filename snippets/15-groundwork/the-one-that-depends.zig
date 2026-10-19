//! title: The One That Depends on the Build
//! fails
//! Plain `+` on values that overflow, in a build that still has the check.
//!
//! The build is `.safe`, and in that build the result is defined: the check
//! runs and the program stops. For this reason, the snippet can have an
//! expected message. The other snippets on the site are `.small` builds. In a
//! `.small` build, there is no check and no promise about the result. Thus no
//! correct message exists to assert.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // 300 does not fit in a u8. In this build, the check runs and the program
    // stops here. ReleaseFast and ReleaseSmall have no check, and the value is
    // undefined. The value does not always wrap.
    const sum = a + b;

    std.debug.print("sum: {d}\n", .{sum});
}
