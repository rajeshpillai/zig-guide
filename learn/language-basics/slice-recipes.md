# Slice Recipes

> Reverse, rotate, shift and search a slice, in place and without an allocator.

A slice is a pointer and a length, so everything here rewrites memory that
already exists. No allocator appears on this page.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.slice-recipes`)*

## In place means the length does not change

`std.mem.reverse` and `std.mem.rotate` rewrite the same bytes and hand nothing
back. Both work on any `[]T`.

Reversing a `[]const u8` reverses the bytes, not the characters. On anything
outside ASCII that splits every multi-byte sequence and produces invalid UTF-8,
which is one of the things
[Unicode Recipes](https://www.ziglang.in/learn/standard-library/unicode-recipes/) is about.

## Overlapping copies

`@memcpy` requires that the source and destination do not overlap. Shifting
elements within one slice always overlaps, and a release build will not tell
you: the check is a safety check, so it disappears exactly where the bug is
expensive.

`@memmove` is the one that handles it. It works in either direction, so unlike
the older `std.mem.copyForwards` and `std.mem.copyBackwards` pair there is no
direction to pick and no way to pick it wrong. Those two are now deprecated in
favour of the builtin.

The rule is worth carrying: `@memcpy` when you know the ranges are disjoint,
`@memmove` when they might not be.

## Removing an element

Shift the tail down over the gap, then reslice one shorter. The backing array
keeps its length forever; the slice is the thing that shrinks. This is what
`orderedRemove` does for you on an `ArrayList`, and it is worth seeing once
without the container.

## Stopping at a value

`std.mem.sliceTo` takes the part of a buffer before the first occurrence of a
value. It is the answer whenever something else filled a fixed buffer and
terminated its own output, which includes most C interop.

## Min, max, and all the same

`std.mem.findMin` and `findMax` return **indices**, not values. That reads
oddly until the moment you have a second array of labels lined up with the
first, which is the case they are built for. `std.mem.allEqual` answers the
whole-slice question without a loop.

## Indices belong to the slice they came from

An offset found in one slice means nothing measured against another.
`std.mem.find` on a sub-slice returns a position relative to that sub-slice, and
using it against the parent is a bug the type system cannot see, because both
are `[]const u8`.

Convert by adding the sub-slice's own offset, or keep searching the parent and
narrow afterwards. This is the trap that makes the whole `find` family dangerous
once sub-slices are in play.

Searching a *sorted* slice, and sorting one in the first place, are in
[Sorting](https://www.ziglang.in/learn/standard-library/sorting/).
