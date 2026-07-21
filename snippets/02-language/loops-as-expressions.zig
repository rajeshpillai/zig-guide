//! title: Loops as Expressions
//! `else` supplies the value when the loop never breaks.

const std = @import("std");
const expect = std.testing.expect;

fn firstIndexOf(haystack: []const u8, needle: u8) ?usize {
    // The `else` branch runs only if the loop finished without breaking,
    // so "not found" cannot be forgotten.
    return for (haystack, 0..) |c, i| {
        if (c == needle) break i;
    } else null;
}

test "for as an expression" {
    try expect(firstIndexOf("hello", 'l').? == 2);
    try expect(firstIndexOf("hello", 'z') == null);
}

test "while as an expression" {
    var i: u32 = 0;
    const result = while (i < 10) : (i += 1) {
        if (i == 4) break i * 10;
    } else 0;
    try expect(result == 40);
}

test "the else branch runs when nothing breaks" {
    var i: u32 = 0;
    const result = while (i < 3) : (i += 1) {
        if (i == 99) break @as(u32, 1);
    } else @as(u32, 2);
    try expect(result == 2);
}
