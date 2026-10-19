//! title: Build Modes
//! The four modes, and the cost of each one. The tags are lowercase from 0.17-dev.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // The build makes these snippets as .small. Master changed the mode tags
    // to lowercase: .Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall are now
    // .debug/.safe/.fast/.small.
    try expect(builtin.optimize == .small);
}

test "safety checks follow the mode" {
    // True in .debug and .safe. False in .fast and .small.
    const safety_on = switch (builtin.optimize) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    try expect(!safety_on); // because this build is .small
}

test "safety can be forced back on for a scope" {
    // Use this call to keep the bounds checks in one risky function of a
    // ReleaseFast build.
    @setRuntimeSafety(true);
    var index: usize = 1;
    _ = &index;
    const array = [_]u8{ 1, 2, 3 };
    try expect(array[index] == 2);
}

test "branch hints and unreachable" {
    // In safety builds, `unreachable` panics. In ReleaseFast, `unreachable`
    // is a promise to the optimiser. If the program gets to it, the result
    // is illegal behaviour.
    const value: u8 = 2;
    switch (value) {
        1, 2, 3 => {},
        else => unreachable,
    }
}
