//! title: Printing Any Struct
//! One function, every struct type, resolved at compile time.

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

// Generic over any struct type. The inline for unrolls at compile time, so
// each field is printed with a format picked for its actual type. There is
// no runtime reflection: by the time this runs, it is straight-line code.
fn printStruct(out: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";
    try out.print("{s} {{\n", .{@typeName(T)});
    // Names and types are parallel arrays, guaranteed the same length.
    // (They used to be one `fields` array of structs; that shape is gone.)
    inline for (info.field_names, info.field_types) |name, Field| {
        const v = @field(value, name);
        // Strings need {s}; everything else gets a reasonable default from
        // {any}. The branch is comptime, so only one side is compiled per
        // field.
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
