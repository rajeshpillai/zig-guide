# Recipe: Printing Any Struct

> Comptime reflection builds a debug printer that works for every struct type.

## The problem

You want to dump any struct for debugging or logging: field names, values,
strings quoted, without writing a print function per type and without runtime
reflection machinery. In most languages this costs a reflection API and some
runtime overhead. In Zig it is a loop that runs at compile time.

## The plan

1. Take the value as `anytype` and get its type with `@TypeOf`.
2. Ask the compiler for the struct's shape with `@typeInfo`.
3. `inline for` over the fields. The loop unrolls at compile time, so each
   iteration can use a different field type, and the generated code is
   straight-line prints.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.struct-printer`)*

## The shape of `@typeInfo` changed

If you learned this API before, note the delta: `@typeInfo(T).@"struct"` used
to expose one `fields` slice of `StructField` structs, each with a `name` and
a `type`. Current master splits that into parallel arrays: `field_names`,
`field_types`, and `field_attrs`, guaranteed to have the same length. Iterating
names and types together is a two-slice `inline for`:

```zig
inline for (info.field_names, info.field_types) |name, Field| {
    const v = @field(value, name);
}
```

A tutorial showing `.fields` with `field.name` and `field.type` no longer
compiles. The idea is unchanged; only the field layout moved.

## Why the branch costs nothing

`if (comptime Field == []const u8)` is decided while compiling, per field.
For `host` the compiler emits only the quoted-string print; for `port` only
the `{any}` print. The other branch is not compiled at all, which also means
this works even when a branch would be a type error for the other fields.

## Variations

- **Nested structs:** recurse when `@typeInfo(Field)` is itself a struct.
  Watch for cycles if types can reference themselves through pointers.
- **The built-in shortcut:** `{any}` on a whole struct already prints
  something usable. Write a custom printer when you need control over
  format, indentation, or which fields appear.
- **Enums and unions:** `{t}` prints tag names directly; combine with this
  recipe for tagged unions.
