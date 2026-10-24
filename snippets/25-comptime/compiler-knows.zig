//! title: Know What the Compiler Knows
//! Which values the compiler knows, and four ways to use them.

const std = @import("std");

fn square(x: u32) u32 {
    return x * x;
}

// A function does not decide where it runs. The caller decides.
// `@inComptime()` tells the function which case is true.
fn where() []const u8 {
    return if (@inComptime()) "compile time" else "runtime";
}

// A comptime parameter can be part of the return type.
// Each different `n` makes a different function.
fn repeat(comptime n: usize, char: u8) [n]u8 {
    return @splat(char);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // 1. A `const` with a literal value is comptime-known.
    //    A `var` is runtime-known, even when its value never changes.
    const width = 8;
    var height: u32 = 3;
    _ = &height;
    try out.print("1. width: {s}, height: {s}\n", .{ @typeName(@TypeOf(width)), @typeName(@TypeOf(height)) });

    // A comptime-known value can be an array length. `height` cannot.
    const row: [width]u8 = @splat('#');
    try out.print("   row: {s}\n", .{&row});

    // 2. The same function, called two ways.
    const at_compile = comptime where();
    const at_run = where();
    try out.print("2. comptime where(): {s}\n", .{at_compile});
    try out.print("   where(): {s}\n", .{at_run});

    // 3. A labelled block after `comptime` runs during compilation.
    //    The binary contains only the array, not the loop.
    const squares = comptime blk: {
        var table: [6]u32 = undefined;
        for (&table, 0..) |*slot, i| slot.* = square(@intCast(i));
        break :blk table;
    };
    try out.print("3. squares: {any}\n", .{squares});

    // 4. A comptime parameter sets the length of the result.
    const three = repeat(3, 'a');
    const five = repeat(5, 'b');
    try out.print("4. {s} is a {s}\n", .{ &three, @typeName(@TypeOf(three)) });
    try out.print("   {s} is a {s}\n", .{ &five, @typeName(@TypeOf(five)) });

    // 5. A `comptime var` lives only during compilation. An `inline for`
    //    runs its body once for each item, so the counter sees each one.
    const words = .{ "red", "green", "blue" };
    comptime var total = 0;
    inline for (words) |word| total += word.len;
    try out.print("5. letters in {d} words: {d}\n", .{ words.len, total });
}
