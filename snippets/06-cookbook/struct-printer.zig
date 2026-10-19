//! title: Print Any Struct
//! One function for all struct types, resolved at compile time.

const std = @import("std");

const Server = struct {
    host: []const u8,
    port: u16,
    debug: bool,
};

const Point = struct {
    x: f32,
    y: f32,
};

// Generic over all struct types. The inline for unrolls at compile time.
// Thus each field gets a format for its actual type. There is no reflection
// at runtime. When this function runs, it is a straight line of code.
fn printStruct(out: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";
    try out.print("{s} {{\n", .{@typeName(T)});
    // Names and types are parallel arrays, with a guaranteed equal length.
    // (Before, they were one `fields` array of structs. Zig removed that shape.)
    inline for (info.field_names, info.field_types) |name, Field| {
        const v = @field(value, name);
        // Strings need {s}. All other types get a usable default from {any}.
        // The branch is comptime. Thus the compiler compiles only one side for
        // each field.
        if (comptime Field == []const u8) {
            try out.print("  {s}: \"{s}\"\n", .{ name, v });
        } else {
            try out.print("  {s}: {any}\n", .{ name, v });
        }
    }
    try out.print("}}\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try printStruct(out, Server{ .host = "0.0.0.0", .port = 8080, .debug = true });
    try printStruct(out, Point{ .x = 1.5, .y = -2.25 });

    try out.flush();
}
