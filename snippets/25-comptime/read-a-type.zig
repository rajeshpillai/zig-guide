//! title: Read a Type
//! Walk the fields of a struct, an enum and a union, then use the walk.

const std = @import("std");
const Writer = std.Io.Writer;

const Config = struct {
    name: []const u8 = "server",
    port: u16 = 8080,
    verbose: bool = false,
    retries: u8,

    pub const max_port = 9000;

    pub fn isDefaultPort(self: Config) bool {
        return self.port == 8080;
    }
};

const Level = enum(u8) { debug, info, warn = 10, err };

const Shape = union(enum) {
    circle: f32,
    square: f32,
    empty: void,
};

// Print each field of a struct with its type and its default value.
fn describeStruct(out: *Writer, comptime T: type) !void {
    const info = @typeInfo(T).@"struct";
    try out.print("{d} fields, {d} declarations\n", .{ info.field_names.len, info.decl_names.len });
    // The three arrays have the same length and the same order.
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        try out.print("  {s}: {s}", .{ name, @typeName(F) });
        if (attrs.defaultValue(F)) |default| {
            if (F == []const u8) {
                try out.print(" = \"{s}\"", .{default});
            } else {
                try out.print(" = {any}", .{default});
            }
        } else {
            try out.print(" (no default)", .{});
        }
        try out.print("\n", .{});
    }
    inline for (info.decl_names) |decl| try out.print("  pub {s}\n", .{decl});
}

// Two values of one struct type. Print only the fields that are different.
fn diff(out: *Writer, old: anytype, new: @TypeOf(old)) !void {
    const T = @TypeOf(old);
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
        const a = @field(old, name);
        const b = @field(new, name);
        // `==` on a slice is not allowed. Compare the bytes instead.
        const same = if (F == []const u8) std.mem.eql(u8, a, b) else a == b;
        if (!same) {
            if (F == []const u8) {
                try out.print("  {s}: \"{s}\" -> \"{s}\"\n", .{ name, a, b });
            } else {
                try out.print("  {s}: {any} -> {any}\n", .{ name, a, b });
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("Config: ", .{});
    try describeStruct(out, Config);

    // Questions with a yes or no answer, all at compile time.
    try out.print("@hasField(Config, \"port\"): {}\n", .{@hasField(Config, "port")});
    try out.print("@hasField(Config, \"host\"): {}\n", .{@hasField(Config, "host")});
    try out.print("@hasDecl(Config, \"isDefaultPort\"): {}\n", .{@hasDecl(Config, "isDefaultPort")});
    try out.print("@FieldType(Config, \"port\"): {s}\n", .{@typeName(@FieldType(Config, "port"))});

    const level = @typeInfo(Level).@"enum";
    try out.print("Level: tag type {s}\n", .{@typeName(level.tag_type)});
    inline for (level.field_names, level.field_values) |name, value| {
        try out.print("  {s} = {d}\n", .{ name, value });
    }

    const shape = @typeInfo(Shape).@"union";
    try out.print("Shape: {d} variants\n", .{shape.field_names.len});
    inline for (shape.field_names, shape.field_types) |name, P| {
        try out.print("  {s}: {s}\n", .{ name, @typeName(P) });
    }

    const before: Config = .{ .retries = 3 };
    const after: Config = .{ .name = "api", .retries = 3, .verbose = true };
    try out.print("diff(before, after):\n", .{});
    try diff(out, before, after);
}
