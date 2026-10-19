//! title: Pointers
//! `*T` always points at exactly one `T`, and is never null.

const std = @import("std");
const expect = std.testing.expect;

fn increment(num: *u8) void {
    num.* += 1;
}

test "take an address and dereference" {
    var x: u8 = 1;
    increment(&x);
    try expect(x == 2);
}

test "pointers to const are const" {
    const x: u8 = 1;
    // Here `&x` is a `*const u8`. A write through it does not compile.
    const ptr: *const u8 = &x;
    try expect(ptr.* == 1);
}

test "pointers are never null" {
    // There is no null `*T`. Write `?*T` for a pointer that can be absent.
    // It uses no extra space, because the null address is the tag.
    var x: u8 = 5;
    const ptr: *u8 = &x;
    const maybe: ?*u8 = ptr;
    try expect(maybe != null);
    try expect(@sizeOf(?*u8) == @sizeOf(*u8));
}
