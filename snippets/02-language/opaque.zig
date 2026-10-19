//! title: Opaque
//! A type with unknown size and layout: a handle you can only point at.

const std = @import("std");
const expect = std.testing.expect;

// Usually this type replaces a C type that has no definition that you can
// see: `typedef struct Window Window;`
const Window = opaque {
    // Opaque types can still have methods.
    pub fn close(self: *Window) void {
        _ = self;
    }
};

const Handle = opaque {};

test "opaque types are only usable behind a pointer" {
    // `var w: Window = ...` is impossible, because the size is unknown. Only
    // pointers to a `Window` exist. C code uses C handles in the same way.
    var storage: u32 = 0;
    const handle: *Handle = @ptrCast(&storage);
    try expect(@TypeOf(handle) == *Handle);
}

test "distinct opaque types do not mix" {
    // *Window and *Handle are unrelated types. Thus the compiler does not let
    // you use one type where the other type is necessary. C's void* allows it.
    try expect(*Window != *Handle);
}
