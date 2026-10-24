//! title: Reject Bad Input with @compileError
//! A generic function that checks its argument type and explains a refusal.

const std = @import("std");

// The item type of an array, a slice or a pointer to an array.
// Any other type stops the build with a message that names the type.
fn Item(comptime T: type) type {
    const I = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            .one => switch (@typeInfo(info.child)) {
                .array => |array| array.child,
                else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
            },
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

// A function that needs a method. The check runs before the body, thus
// the message names the method that the type does not have, not a line inside the loop.
fn describeAll(out: *std.Io.Writer, items: anytype) !void {
    const T = @typeInfo(@TypeOf(items)).pointer.child;
    const E = @typeInfo(T).array.child;
    if (!@hasDecl(E, "describe")) {
        @compileError(@typeName(E) ++ " needs a `pub fn describe`");
    }
    for (items) |item| try item.describe(out);
}

const Dog = struct {
    name: []const u8,
    pub fn describe(self: Dog, out: *std.Io.Writer) !void {
        try out.print("  dog {s}\n", .{self.name});
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const bytes = [_]u8{ 10, 20, 30 };
    const prices = [_]f64{ 1.5, 2.25 };
    const prices_slice: []const f64 = &prices;
    try out.print("sum(array of u8) = {d}\n", .{sum(bytes)});
    try out.print("sum(&array of u8) = {d}\n", .{sum(&bytes)});
    try out.print("sum(slice of f64) = {d}\n", .{sum(prices_slice)});

    // `comptimePrint` formats during compilation. The result is a string
    // constant, the same kind of value as a literal.
    const label = comptime std.fmt.comptimePrint("{d} dogs", .{2});
    try out.print("{s}:\n", .{label});
    const dogs = [_]Dog{ .{ .name = "Moti" }, .{ .name = "Raja" } };
    try describeAll(out, &dogs);
}
