//! title: Zig 0.17
//! The new shapes on master since 0.16.0, each one printing what it does.
//! deprecated: std.fmt.allocPrint
//! deprecated: std.fmt.bufPrint

const std = @import("std");

const Point = struct { x: i32, y: i32 };
const Color = enum(u8) { red = 1, green = 2, blue = 4 };

fn repeat(out: *std.Io.Writer) !void {
    // `"-" ** 12` compiled on 0.16.0. On master `**` is gone.
    const rule: [12]u8 = @splat('-');
    try out.print("{s}\n", .{&rule});
}

fn reflection(out: *std.Io.Writer) !void {
    // Names, types and values are parallel arrays now, not one `fields` array.
    const s = @typeInfo(Point).@"struct";
    inline for (s.field_names, s.field_types) |name, T| {
        try out.print("Point.{s}: {s}\n", .{ name, @typeName(T) });
    }

    const e = @typeInfo(Color).@"enum";
    inline for (e.field_names, e.field_values) |name, value| {
        try out.print("Color.{s} = {d}\n", .{ name, value });
    }
}

fn parse(text: []const u8) !u8 {
    return std.fmt.parseInt(u8, text, 10);
}

fn parseLogged(out: *std.Io.Writer, text: []const u8) !u8 {
    // `errdefer |err|` no longer parses. Catch, log, and return the error.
    return parse(text) catch |err| {
        try out.print("could not parse \"{s}\": {t}\n", .{ text, err });
        return err;
    };
}

fn describe(mode: std.lang.Optimize) []const u8 {
    // The build modes are lowercase: .debug, .safe, .fast, .small.
    return switch (mode) {
        .debug => "debug: every check on, no optimisation",
        .safe => "safe: optimised, checks kept",
        .fast => "fast: optimised, checks removed",
        .small => "small: optimised for size, checks removed",
    };
}

fn memory(out: *std.Io.Writer) !void {
    // DebugAllocator is now SafeAllocator, and it takes its backing allocator.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();

    // std.fmt.allocPrint is now a method on the allocator.
    const owned = try gpa.print("{d} + {d} = {d}", .{ 2, 3, 2 + 3 });
    try out.print("gpa.print: {s}\n", .{owned});
    gpa.free(owned);

    // std.fmt.bufPrint is now std.mem.print.
    var buf: [32]u8 = undefined;
    const text = try std.mem.print(&buf, "{d} items", .{3});
    try out.print("mem.print: {s}\n", .{text});

    // stackFallback is gone. BufferFirstAllocator uses the buffer first.
    var stack: [64]u8 = undefined;
    var first: std.heap.BufferFirstAllocator = .init(&stack, gpa);
    const small = try first.allocator().alloc(u8, 16);
    try out.print("BufferFirstAllocator gave {d} bytes\n", .{small.len});
    first.allocator().free(small);

    // deinit returns a leak count instead of .ok or .leak.
    try out.print("leaks: {d}\n", .{safe.deinit()});
}

fn containers(out: *std.Io.Writer) !void {
    // initEmpty() is gone. Declare the type and use .empty.
    var seen: std.bit_set.Static(64) = .empty;
    seen.set(3);
    seen.set(10);
    try out.print("bits set: {d}\n", .{seen.count()});

    // getLast() and getLastOrNull() became one method that returns an optional.
    var backing: [3]u8 = undefined;
    var list: std.ArrayList(u8) = .initBuffer(&backing);
    try out.print("last of an empty list: {?d}\n", .{list.last()});
    list.appendSliceAssumeCapacity(&.{ 4, 8, 15 });
    try out.print("last: {?d}\n", .{list.last()});

    // The element now comes before the count. The old order still compiles.
    const rolls = [_]u8{ 6, 6, 1, 6 };
    try out.print("at least three sixes: {}\n", .{std.mem.containsAtLeastScalar(u8, &rolls, 6, 3)});
}

fn builtins(out: *std.Io.Writer) !void {
    try out.print("@divCeil(7, 2) = {d}\n", .{@divCeil(@as(u32, 7), 2)});
    try out.print("@backingInt(Color.blue) = {d}\n", .{@backingInt(Color.blue)});
    const c: Color = @fromBackingInt(2);
    try out.print("@fromBackingInt(2) = {t}\n", .{c});
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try repeat(out);
    try reflection(out);
    try repeat(out);
    _ = parseLogged(out, "300") catch {};
    try out.print("{s}\n", .{describe(.fast)});
    try repeat(out);
    try memory(out);
    try repeat(out);
    try containers(out);
    try repeat(out);
    try builtins(out);

    try out.flush();
}
