//! title: total with u8 readings
//! compile-fails
//! The same `total`, called with u8 readings. The guard stops the build.

const std = @import("std");

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

pub fn main() void {
    const raw = [_]u8{ 200, 100, 0, 35, 255 };
    std.debug.print("{d}\n", .{total(@as([]const u8, &raw))});
}
