//! title: A Generic Function Without a Guard
//! compile-fails
//! `sum` with no check of its argument, called with a list of strings.

const std = @import("std");

fn sum(values: anytype) @typeInfo(@TypeOf(values)).array.child {
    var total: @typeInfo(@TypeOf(values)).array.child = 0;
    for (values) |v| total += v;
    return total;
}

pub fn main() void {
    const names = [_][]const u8{ "Moti", "Raja" };
    std.debug.print("{any}\n", .{sum(names)});
}
