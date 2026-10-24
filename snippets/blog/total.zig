//! title: total with u32 readings
//! The `total` function from the post, with the guard, on readings it accepts.

const std = @import("std");

/// The sum of the items, in the type of the items.
pub fn total(values: anytype) Item(@TypeOf(values)) {
    var sum: Item(@TypeOf(values)) = 0;
    for (values) |v| sum += v;
    return sum;
}

fn Item(comptime T: type) type {
    const I = @typeInfo(T).pointer.child;
    if (@typeInfo(I) == .int and @bitSizeOf(I) < 32) {
        @compileError("total: " ++ @typeName(I) ++ " items overflow after a few values; convert them to u32 first");
    }
    return I;
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // Rain in tenths of a millimetre, one value each hour.
    const raw = [_]u8{ 200, 100, 0, 35, 255 };
    var wide: [raw.len]u32 = undefined;
    for (raw, &wide) |r, *w| w.* = r;
    try out.print("total: {d}\n", .{total(@as([]const u32, &wide))});
}
