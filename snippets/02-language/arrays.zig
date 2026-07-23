//! title: Arrays
//! `[N]T`: length is part of the type.

const std = @import("std");
const expect = std.testing.expect;

test "array literal and length" {
    const message = [5]u8{ 'h', 'e', 'l', 'l', 'o' };
    try expect(message.len == 5);

    // `_` infers the length from the literal.
    const alt = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    try expect(alt.len == 5);
}

test "arrays are values, not pointers" {
    const a = [_]i32{ 1, 2, 3 };
    var b = a; // a full copy
    b[0] = 99;
    try expect(a[0] == 1);
    try expect(b[0] == 99);
}

test "concatenate at comptime" {
    const joined = [_]i32{ 1, 2 } ++ [_]i32{ 3, 4 };
    try expect(joined.len == 4);
    try expect(joined[3] == 4);
}

test "repeat with @splat" {
    // Older tutorials show `"-" ** 5`. The `**` repeat operator no longer
    // exists on master (`**` does not even tokenise), so use `@splat`,
    // which fills an array of known length with one value.
    const dashes: [5]u8 = @splat('-');
    try expect(std.mem.eql(u8, &dashes, "-----"));
}
