//! title: A Generic Function With a Guard
//! compile-fails
//! The `sum` from this chapter, called with a list of strings.

const std = @import("std");

fn Item(comptime T: type) type {
    const I = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
        },
        else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
    };
    switch (@typeInfo(I)) {
        .int, .float => {},
        else => @compileError(std.fmt.comptimePrint(
            "sum: the items of {s} are {s}, not numbers",
            .{ @typeName(T), @typeName(I) },
        )),
    }
    return I;
}

fn sum(values: anytype) Item(@TypeOf(values)) {
    var total: Item(@TypeOf(values)) = 0;
    for (values) |v| total += v;
    return total;
}

pub fn main() void {
    const names = [_][]const u8{ "Moti", "Raja" };
    std.debug.print("{any}\n", .{sum(names)});
}
