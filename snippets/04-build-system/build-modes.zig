//! title: Build Modes
//! The four modes, and what each trades away. Tags are lowercase since 0.17-dev.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // These snippets are built as .small. Master lowercased the mode tags:
    // .Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall are now
    // .debug/.safe/.fast/.small.
    try expect(builtin.mode == .small);
}

test "safety checks follow the mode" {
    // True in .debug and .safe, false in .fast and .small.
    const safety_on = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    try expect(!safety_on); // because we are in .small
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
