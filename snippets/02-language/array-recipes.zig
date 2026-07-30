//! title: Array Recipes
//! Grids, comptime tables, and getting an array back out of a slice.

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
