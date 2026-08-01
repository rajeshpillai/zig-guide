//! title: The One That Depends on the Build
//! norun
//! Plain `+` on values that overflow: a crash in Debug, undefined in ReleaseSmall.
//!
//! `//! norun` and deliberately without a `.expected` file. In a safety build
//! this panics, and in a release build the result is undefined, so there is no
//! correct output for CI to assert. Pinning whatever this compiler happens to
//! produce today would be asserting undefined behaviour, which is the one
//! thing this chapter is telling readers not to do.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // In Debug and ReleaseSafe: stops here with "integer overflow".
    // In ReleaseFast and ReleaseSmall: no check, and no promise about the
    // value. Not "wraps". Undefined.
    const sum = a + b;

    std.debug.print("sum: {d}\n", .{sum});
}
