//! title: Array Recipes
//! Grids, comptime tables, and how to get an array from a slice.

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
