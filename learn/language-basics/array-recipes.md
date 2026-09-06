# Array Recipes

> Grids, comptime lookup tables, and getting an array back out of a slice.

Three things people reach for once arrays stop being toy examples: a grid, a
table computed at compile time, and a fixed-size array taken back out of a
slice. All three are language mechanics. None of them needs an allocator.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a grid is an array of arrays" {
    const grid = [3][3]u8{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    };

    // Both lengths are part of the type, and the whole thing is one
    // contiguous block: nine bytes, no pointers anywhere.
    try expect(grid.len == 3); // rows
    try expect(grid[0].len == 3); // columns
    try expect(@TypeOf(grid[0]) == [3]u8);
    try expect(@sizeOf(@TypeOf(grid)) == 9);

    try expect(grid[1][2] == 6); // row first, then column
}

test "walk a grid with nested for" {
    const grid = [2][3]u8{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
    };

    var sum: u32 = 0;
    for (grid) |row| {
        for (row) |cell| sum += cell;
    }
    try expect(sum == 21);
}

test "the outer loop hands you a copy" {
    var grid = [2][2]u8{
        .{ 1, 2 },
        .{ 3, 4 },
    };

    // Arrays are values, so `row` is a copy and writing to it changes nothing.
    for (grid) |row| {
        var mutable = row;
        mutable[0] = 99;
    }
    try expect(grid[0][0] == 1);

    // Take pointers at both levels to write through.
    for (&grid) |*row| {
        for (row) |*cell| cell.* += 10;
    }
    try expect(grid[0][0] == 11);
    try expect(grid[1][1] == 14);
}

test "one flat array, computed indices" {
    const width = 4;
    const height = 3;
    var cells: [width * height]u8 = @splat(0);

    // The type no longer carries the shape, so the stride is yours to keep
    // right. Worth it when the dimensions are not both compile-time constants.
    cells[1 * width + 2] = 7;

    try expect(cells[6] == 7);
    try expect(cells.len == 12);
}

test "build a lookup table at comptime" {
    // Declare undefined storage, fill it in a loop, break the finished array
    // out of the block. The result is a constant baked into the binary.
    const hex_digits = comptime blk: {
        var table: [16]u8 = undefined;
        for (&table, 0..) |*slot, i| {
            slot.* = if (i < 10) '0' + @as(u8, i) else 'a' + @as(u8, i - 10);
        }
        break :blk table;
    };

    try expect(hex_digits[0] == '0');
    try expect(hex_digits[10] == 'a');
    try expect(hex_digits[15] == 'f');
}

test "the table really is a compile-time constant" {
    const sizes = comptime blk: {
        var table: [4]usize = undefined;
        for (&table, 0..) |*slot, i| slot.* = i * 2;
        break :blk table;
    };

    // An array length has to be known at compile time, so this only compiles
    // if the value came out of comptime. That is the proof, not the claim.
    const buf: [sizes[3]]u8 = @splat(0);
    try expect(buf.len == 6);
}

test "turn a slice back into an array" {
    const numbers = [_]u8{ 1, 2, 3, 4, 5 };
    const slice: []const u8 = &numbers;

    // .* on a slice of comptime-known length copies out a real array, which
    // puts the length back in the type.
    const first_three = slice[0..3].*;
    try expect(@TypeOf(first_three) == [3]u8);
    try expect(first_three.len == 3);

    // It is a copy, so writing to it leaves the original alone.
    var copy = first_three;
    copy[0] = 99;
    try expect(numbers[0] == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.array-recipes`)*

## A grid is an array of arrays

`[3][3]u8` is nine bytes in one contiguous block. Both lengths are part of the
type, `grid.len` is the row count and `grid[0].len` is the column count, and
`@sizeOf` proves there is no pointer hiding anywhere. Index rows first, then
columns.

This is not the same type as `[][]u8`, a slice of slices, which is a list of
pointers to rows that may live anywhere. The nested array is one
allocation-free block; the slice of slices is however many the code that built
it made.

## The outer loop hands you a copy

Arrays are values, which the [Arrays](https://www.ziglang.in/learn/language-basics/arrays/) chapter
states. In a nested loop it stops being an abstract rule: `for (grid) |row|`
copies each row, so writing through `row` changes nothing at all and the
compiler has no reason to complain.

`for (&grid) |*row|` iterates pointers, and then `for (row) |*cell|` reaches
the elements. Both levels have to be pointers before a write lands.

## Or one flat array

`[width * height]T` with `y * width + x` is the other shape. The type stops
carrying the geometry, so the stride becomes yours to keep right, and in
exchange the dimensions no longer have to be two separate compile-time
constants.

Pick the nested array when the shape is fixed and small. Pick the flat one in
three cases. When the width is computed. When you want to hand the whole thing
to something that takes a `[]T`. Or when the rows are large enough that
copying one by accident would matter.

## Tables built at compile time

Declare `undefined` storage, fill it in a loop, and `break :blk` the finished
array out of the block. Run that inside `comptime` and the result is a
constant baked into the binary, with no initialization code at startup.

The claim is checkable: use one of the table's entries as an array length.
Array lengths must be known at compile time, so if it compiles, the value came
out of comptime. That is a proof rather than a promise.

## From slice back to array

`slice[0..N].*` copies out a real `[N]T`, where `N` has to be known at compile
time. The length moves back into the type, which is what a function expecting
`*const [4]u8` wants.

It is a copy. Writing to the result leaves the original slice untouched.

Concatenating at runtime is a `std.mem.concat` away and lives in [String
Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/); the operations that work on
slices in place are in [Slice Recipes](https://www.ziglang.in/learn/language-basics/slice-recipes/).
