//! title: Build Modes
//! The four modes, and what each trades away.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // These snippets are built as ReleaseSmall.
    try expect(builtin.mode == .ReleaseSmall);
}

test "safety checks follow the mode" {
    // True in Debug and ReleaseSafe, false in ReleaseFast and ReleaseSmall.
    const safety_on = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    try expect(!safety_on); // because we are in ReleaseSmall
}

test "safety can be forced back on for a scope" {
    // Useful for keeping bounds checks in one risky function of an
    // otherwise ReleaseFast build.
    @setRuntimeSafety(true);
    var index: usize = 1;
    _ = &index;
    const array = [_]u8{ 1, 2, 3 };
    try expect(array[index] == 2);
}

test "branch hints and unreachable" {
    // In safety builds `unreachable` panics; in ReleaseFast it is a promise
    // to the optimiser, and reaching it is illegal behaviour.
    const value: u8 = 2;
    switch (value) {
        1, 2, 3 => {},
        else => unreachable,
    }
}
