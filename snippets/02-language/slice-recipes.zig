//! title: Slice Recipes
//! Reverse, rotate, shift and search a slice, in place and without an allocator.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "reverse in place" {
    var digits = [_]u8{ '1', '2', '3', '4' };
    std.mem.reverse(u8, &digits);
    try expectEqualStrings("4321", &digits);

    // This works on any []T. On UTF-8 bytes, it reverses the bytes. Thus it
    // breaks each character that has more than one byte: see Unicode Recipes.
}

test "rotate by n" {
    var buf = [_]u8{ 'a', 'b', 'c', 'd', 'e' };

    // The first two move to the end. Nothing allocates, and the length does
    // not change.
    std.mem.rotate(u8, &buf, 2);
    try expectEqualStrings("cdeab", &buf);
}

test "overlapping copies are @memmove, not @memcpy" {
    // @memcpy requires that the two ranges do not overlap. A shift inside one
    // slice always overlaps, and a release build does not report the mistake.
    var shift_left = [_]u8{ 'a', 'b', 'c', 'd' };
    @memmove(shift_left[0..3], shift_left[1..4]);
    try expectEqualStrings("bcdd", &shift_left);

    // @memmove works in the two directions. Thus you cannot select the wrong
    // direction. std.mem.copyForwards and copyBackwards are deprecated, and
    // @memmove replaces them.
    var shift_right = [_]u8{ 'a', 'b', 'c', 'd' };
    @memmove(shift_right[1..4], shift_right[0..3]);
    try expectEqualStrings("aabc", &shift_right);
}

test "remove an element from the middle" {
    var backing = [_]u8{ 10, 20, 30, 40, 50 };
    var items: []u8 = &backing;

    // Move the tail one position lower over the gap. Then make the slice one
    // element shorter. The array keeps its length. Only the slice becomes shorter.
    const remove_at = 1;
    @memmove(items[remove_at .. items.len - 1], items[remove_at + 1 ..]);
    items = items[0 .. items.len - 1];

    try expect(items.len == 4);
    try expect(items[1] == 30);
    try expect(backing.len == 5); // not changed
}

test "sliceTo stops at a value" {
    // A different part of the program filled this buffer and terminated it.
    // Take the useful part. You do not have to scan for the terminator.
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0..5], "hello");

    try expectEqualStrings("hello", std.mem.sliceTo(&buf, 0));
}

test "min, max, and all the same" {
    const readings = [_]u8{ 12, 3, 40, 7 };

    // These functions return indices, not values. An index is what you need
    // when a second array holds the labels.
    try expect(std.mem.findMin(u8, &readings) == 1);
    try expect(std.mem.findMax(u8, &readings) == 2);
    try expect(readings[std.mem.findMax(u8, &readings)] == 40);

    try expect(std.mem.allEqual(u8, "aaaa", 'a'));
    try expect(!std.mem.allEqual(u8, &readings, 12));
}

test "dedup a sorted slice in place" {
    var values = [_]u8{ 1, 1, 2, 3, 3, 3, 4 };

    // Two indices: one index reads, and one index writes the kept elements
    // forward. Nothing allocates. The result is a slice of the new length.
    var write: usize = 0;
    for (values, 0..) |value, read| {
        if (read > 0 and value == values[read - 1]) continue;
        values[write] = value;
        write += 1;
    }
    const unique = values[0..write];

    try expect(unique.len == 4);
    try expect(std.mem.eql(u8, unique, &.{ 1, 2, 3, 4 }));
}

test "indices belong to the slice they came from" {
    const all = "abcdefgh";
    const mid = all[2..6]; // "cdef"

    // An offset from one slice has no meaning in a different slice. Thus each
    // find function is dangerous when you use a sub-slice.
    try expect(std.mem.find(u8, all, "de").? == 3);
    try expect(std.mem.find(u8, mid, "de").? == 1);

    // mid[1..3] is all[3..5]. To convert, add the offset of the sub-slice.
    try expectEqualStrings(mid[1..3], all[3..5]);
}
