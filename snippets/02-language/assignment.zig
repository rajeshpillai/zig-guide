//! title: Assignment
//! `const` by default, and `var` only when you must change the value.

const std = @import("std");
const expect = std.testing.expect;

test "const and var" {
    const constant: i32 = 5; // cannot get a new value
    var variable: u32 = 5000; // can get a new value
    variable += 1;

    // The compiler can infer the type from the value.
    const inferred_constant = @as(i32, 5);
    var inferred_variable = @as(u32, 5000);
    inferred_variable += 1;

    try expect(constant == 5);
    try expect(variable == 5001);
    try expect(inferred_constant == 5);
    try expect(inferred_variable == 5001);
}

test "undefined leaves memory uninitialised" {
    // `undefined` means "I will assign this before I read it". A read before
    // the assignment is illegal behaviour. The value is not always zero.
    var x: i32 = undefined;
    x = 7;
    try expect(x == 7);
}
