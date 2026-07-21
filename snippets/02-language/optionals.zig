//! title: Optionals
//! `?T` is either a `T` or `null`, unwrapped with payload capture.

const std = @import("std");
const expect = std.testing.expect;

test "optional payload capture" {
    var maybe: ?i32 = null;
    try expect(maybe == null);

    maybe = 42;
    if (maybe) |value| {
        try expect(value == 42);
    } else {
        unreachable;
    }
}

test "orelse supplies a default" {
    const nothing: ?u32 = null;
    try expect((nothing orelse 7) == 7);
}

test "optional pointers are free" {
    // A `?*T` is the same size as a `*T`; null is the 0 address.
    try expect(@sizeOf(?*i32) == @sizeOf(*i32));
}
