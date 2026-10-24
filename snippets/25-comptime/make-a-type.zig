//! title: Make a Type
//! Build integer, struct, enum and tuple types from comptime values.

const std = @import("std");

const Config = struct {
    name: []const u8 = "server",
    port: u16 = 8080,
    verbose: bool = false,
};

// The same fields as `T`, but each field is optional, with a default of
// `null`. A patch sets only the fields that it wants to change.
fn Partial(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (info.field_types, &types, &attrs) |F, *slot, *attr| {
        slot.* = ?F;
        // The attributes hold the address of the default, not the value.
        // `&@as(?F, null)` is the address of a comptime constant, thus the
        // address stays valid.
        attr.* = .{ .default_value_ptr = &@as(?F, null) };
    }
    return @Struct(.auto, null, info.field_names, &types, &attrs);
}

// Copy each field that the patch sets. Keep each field that it does not set.
fn apply(base: anytype, patch: Partial(@TypeOf(base))) @TypeOf(base) {
    var result = base;
    inline for (@typeInfo(@TypeOf(base)).@"struct".field_names) |name| {
        if (@field(patch, name)) |value| @field(result, name) = value;
    }
    return result;
}

// An enum with one tag for each field of `T`, numbered from 0.
fn FieldTag(comptime T: type) type {
    const names = @typeInfo(T).@"struct".field_names;
    var values: [names.len]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = i;
    return @Enum(u8, .exhaustive, names, &values);
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // 1. An integer of any width from 1 to 65535 bits.
    const U12 = @Int(.unsigned, 12);
    try out.print("1. {s}: {d} bits, {d} bytes, max {d}\n", .{
        @typeName(U12),
        @bitSizeOf(U12),
        @sizeOf(U12),
        std.math.maxInt(U12),
    });

    // 2. A struct made from the fields of another struct.
    const Patch = Partial(Config);
    try out.print("2. Partial(Config):\n", .{});
    inline for (@typeInfo(Patch).@"struct".field_names, @typeInfo(Patch).@"struct".field_types) |name, F| {
        try out.print("   {s}: {s}\n", .{ name, @typeName(F) });
    }

    const base: Config = .{};
    const changed = apply(base, .{ .port = 9090 });
    try out.print("   apply(.{{ .port = 9090 }}): name \"{s}\", port {d}, verbose {}\n", .{
        changed.name,
        changed.port,
        changed.verbose,
    });

    // 3. An enum made from the field names. A `switch` on it must
    //    handle each field, so a new field makes the old switch fail.
    const Tag = FieldTag(Config);
    try out.print("3. FieldTag(Config):", .{});
    inline for (@typeInfo(Tag).@"enum".field_names) |name| try out.print(" .{s}", .{name});
    try out.print("\n", .{});
    const tag: Tag = .port;
    const label = switch (tag) {
        .name => "a string",
        .port => "a number",
        .verbose => "a flag",
    };
    try out.print("   .port is {s}\n", .{label});

    // 4. A tuple type from a list of types.
    const Pair = @Tuple(&.{ u8, bool });
    const pair: Pair = .{ 7, true };
    try out.print("4. @Tuple: {d} fields, values {d} and {}\n", .{
        @typeInfo(Pair).@"struct".field_names.len,
        pair[0],
        pair[1],
    });
}
