//! title: Opaque
//! A type with unknown size and layout: a handle you can only point at.

const std = @import("std");
const expect = std.testing.expect;

// Typically this stands in for a C type you were never given a definition
// for: `typedef struct Window Window;`
const Window = opaque {
    // Opaque types can still have methods.
    pub fn close(self: *Window) void {
        _ = self;
    }
};

const Handle = opaque {};

test "opaque types are only usable behind a pointer" {
    // `var w: Window = ...` is impossible: the size is unknown. Only
    // pointers to it exist, which is exactly how C handles are used.
    var storage: u32 = 0;
    const handle: *Handle = @ptrCast(&storage);
    try expect(@TypeOf(handle) == *Handle);
}

test "distinct opaque types do not mix" {
    // *Window and *Handle are unrelated types, so the compiler prevents
    // passing one where the other is expected, unlike C's void*.
    try expect(*Window != *Handle);
}
