//! title: Slice Recipes
//! Reverse, rotate, shift and search a slice, in place and without an allocator.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "reverse in place" {
    var digits = [_]u8{ '1', '2', '3', '4' };
    std.mem.reverse(u8, &digits);
    try expectEqualStrings("4321", &digits);

    // This works on any []T. Doing it to UTF-8 bytes reverses the bytes, which
    // splits every multi-byte character: see Unicode Recipes.
}

test "rotate by n" {
    var buf = [_]u8{ 'a', 'b', 'c', 'd', 'e' };

    // The first two move to the end. Nothing is allocated and the length is
    // exactly what it was.
    std.mem.rotate(u8, &buf, 2);
    try expectEqualStrings("cdeab", &buf);
}

test "overlapping copies are @memmove, not @memcpy" {
    // @memcpy requires the two ranges not to overlap. Shifting within one slice
    // always overlaps, and in a release build nothing tells you.
    var shift_left = [_]u8{ 'a', 'b', 'c', 'd' };
    @memmove(shift_left[0..3], shift_left[1..4]);
    try expectEqualStrings("bcdd", &shift_left);

    // @memmove works in either direction, so there is no direction to get
    // wrong. std.mem.copyForwards and copyBackwards are deprecated in favour
    // of it.
    var shift_right = [_]u8{ 'a', 'b', 'c', 'd' };
    @memmove(shift_right[1..4], shift_right[0..3]);
    try expectEqualStrings("aabc", &shift_right);
}

test "remove an element from the middle" {
    var backing = [_]u8{ 10, 20, 30, 40, 50 };
    var items: []u8 = &backing;

    // Shift the tail down over the gap, then reslice one shorter. The array
    // keeps its length; the slice is what shrinks.
    const remove_at = 1;
    @memmove(items[remove_at .. items.len - 1], items[remove_at + 1 ..]);
    items = items[0 .. items.len - 1];

    try expect(items.len == 4);
    try expect(items[1] == 30);
    try expect(backing.len == 5); // untouched
}

test "sliceTo stops at a value" {
    // A buffer something else filled and terminated: take the useful part
    // without scanning for the terminator by hand.
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0..5], "hello");

    try expectEqualStrings("hello", std.mem.sliceTo(&buf, 0));
}

test "min, max, and all the same" {
    const readings = [_]u8{ 12, 3, 40, 7 };

    // These return indices, not values, which is what you want when a second
    // array holds the labels.
    try expect(std.mem.findMin(u8, &readings) == 1);
    try expect(std.mem.findMax(u8, &readings) == 2);
    try expect(readings[std.mem.findMax(u8, &readings)] == 40);

    try expect(std.mem.allEqual(u8, "aaaa", 'a'));
    try expect(!std.mem.allEqual(u8, &readings, 12));
}

test "dedup a sorted slice in place" {
    var values = [_]u8{ 1, 1, 2, 3, 3, 3, 4 };

    // Two indices: one reading, one writing survivors forward. Nothing
    // allocates, and the answer is a reslice to the computed length.
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

    // An offset found in one slice means nothing against another. This is what
    // makes the whole find family dangerous across a sub-slice boundary.
    try expect(std.mem.find(u8, all, "de").? == 3);
    try expect(std.mem.find(u8, mid, "de").? == 1);

    // mid[1..3] covers all[3..5]: add the sub-slice's own offset to convert.
    try expectEqualStrings(mid[1..3], all[3..5]);
}
