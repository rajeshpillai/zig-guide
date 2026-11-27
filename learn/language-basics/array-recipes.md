# Array Recipes

> Grids, lookup tables made at compile time, and how to get an array from a slice.

When arrays become larger than small examples, you need three things:

- A grid.
- A table that the compiler calculates at compile time.
- A fixed-size array that you take from a slice.

The three are language mechanics. None of them needs an allocator.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a grid is an array of arrays" {
    const grid = [3][3]u8{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    };

    // The two lengths are part of the type. The grid is one contiguous block
    // of nine bytes. The grid contains no pointers.
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

    // Arrays are values. Thus `row` is a copy, and a write to `row` changes
    // nothing in `grid`.
    for (grid) |row| {
        var mutable = row;
        mutable[0] = 99;
    }
    try expect(grid[0][0] == 1);

    // To write through the loop, use pointers at the two levels.
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

    // The type does not contain the shape. Thus you must keep the stride
    // correct yourself. Use a flat array when one of the dimensions is not
    // a compile-time constant.
    cells[1 * width + 2] = 7;

    try expect(cells[6] == 7);
    try expect(cells.len == 12);
}

test "build a lookup table at comptime" {
    // Declare undefined storage, fill it in a loop, and use break to return
    // the completed array from the block. The result is a constant in the
    // binary.
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

    // The compiler must know an array length at compile time. Thus this line
    // compiles only if the value came from comptime. The compile is the proof.
    const buf: [sizes[3]]u8 = @splat(0);
    try expect(buf.len == 6);
}

test "turn a slice back into an array" {
    const numbers = [_]u8{ 1, 2, 3, 4, 5 };
    const slice: []const u8 = &numbers;

    // .* on a slice with a comptime-known length copies a real array from the
    // slice. The length is then part of the type again.
    const first_three = slice[0..3].*;
    try expect(@TypeOf(first_three) == [3]u8);
    try expect(first_three.len == 3);

    // The result is a copy. Thus a write to the copy does not change the
    // original.
    var copy = first_three;
    copy[0] = 99;
    try expect(numbers[0] == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.array-recipes`)*

## A grid is an array of arrays

`[3][3]u8` is nine bytes in one contiguous block. The two lengths are part of the type. `grid.len` is the number of rows, and `grid[0].len` is the number of columns.

`@sizeOf` shows that the grid contains no hidden pointer. Use the row index first, then the column index.

`[3][3]u8` is not the same type as `[][]u8`, a slice of slices. A slice of slices is a list of pointers to rows, and the rows can be at any location in memory. The nested array is one block, and it needs no allocation. The slice of slices has as many blocks as the code that made it.

## The outer loop gives you a copy

The [Arrays](https://www.ziglang.in/learn/language-basics/arrays/) chapter states that arrays are values. In a nested loop, this rule has a direct effect.

`for (grid) |row|` copies each row. Thus a write through `row` changes nothing in `grid`. The compiler does not give an error, because the code is valid.

`for (&grid) |*row|` iterates over pointers, and then `for (row) |*cell|` gets the elements. The two levels must be pointers before a write can change the grid.

## Use one flat array

The other shape is `[width * height]T` with the index `y * width + x`. The type does not contain the geometry. Thus you must keep the stride correct yourself. In return, the dimensions do not have to be two separate compile-time constants.

Use the nested array when the shape is fixed and small. Use the flat array in these three conditions:

- The program calculates the width.
- You want to give the full array to a function that takes a `[]T`.
- The rows are so large that an accidental copy of one row is a problem.

## Make a table at compile time

To make the table, do these steps:

1. Declare storage that is `undefined`.
2. Fill the storage in a loop.
3. Use `break :blk` to return the completed array from the block.

Do these steps inside `comptime`. The result is a constant in the binary, and the program runs no initialization code at startup.

You can do a check of this. Use one of the entries of the table as an array length. The compiler must know each array length at compile time. Thus, if the code compiles, the value came from comptime.

## Change a slice back to an array

`slice[0..N].*` copies a real `[N]T` from the slice. The compiler must know `N` at compile time. The length moves back into the type. A function that expects `*const [4]u8` needs this.

The result is a copy. A write to the result does not change the original slice.

To join slices at runtime, use `std.mem.concat`. [String Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/) explains it. The operations that change slices in place are in [Slice Recipes](https://www.ziglang.in/learn/language-basics/slice-recipes/).
