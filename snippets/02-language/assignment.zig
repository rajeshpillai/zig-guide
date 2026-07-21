//! title: Assignment
//! `const` by default; `var` only when you must mutate.

const std = @import("std");
const expect = std.testing.expect;

test "const and var" {
    const constant: i32 = 5; // may not be reassigned
    var variable: u32 = 5000; // may be reassigned
    variable += 1;

    // The type can be inferred from the value.
    const inferred_constant = @as(i32, 5);
    var inferred_variable = @as(u32, 5000);
    inferred_variable += 1;

    try expect(constant == 5);
    try expect(variable == 5001);
    try expect(inferred_constant == 5);
    try expect(inferred_variable == 5001);
}

test "undefined leaves memory uninitialised" {
    // `undefined` means "I will assign this before I read it". Reading it
    // first is illegal behaviour, not a guaranteed zero.
    var x: i32 = undefined;
    x = 7;
    try expect(x == 7);
}
