# Recipe: Print Any Struct

> Comptime reflection builds a debug printer that works for all struct types.

Zig can print each struct without a function for each type. The code loops over `@typeInfo` with `inline for` at compile time. On current master, the fields come as the parallel arrays `field_names` and `field_types`, not as the old `fields` slice.

## The problem

You want to show any struct for debugging or [logging](https://www.ziglang.in/learn/standard-library/logging/): the field names, the values, and the strings with quotes. You do not want to write a print function for each type. Also, you do not want reflection machinery at runtime.

In most languages, this needs a reflection API and some overhead at runtime.

## The plan

1. Take the value as `anytype`, and get its type with `@TypeOf`.
2. Ask the compiler for the shape of the struct with `@typeInfo`.
3. Use `inline for` over the fields. The compiler unrolls the loop at compile time. Thus each iteration can use a different field type, and the generated code is a straight line of prints.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.struct-printer`)*

## The shape of `@typeInfo` changed

If you used this API before, note the change. Before, `@typeInfo(T).@"struct"` had one `fields` slice of `StructField` structs, and each one had a `name` and a `type`.

Current master divides that slice into parallel arrays: `field_names`, `field_types` and `field_attrs`. Zig guarantees that the arrays have the same length. To use the names and the types together, write an `inline for` over two slices:

```zig
inline for (info.field_names, info.field_types) |name, Field| {
    const v = @field(value, name);
}
```

A tutorial that shows `.fields` with `field.name` and `field.type` does not compile now. The method is the same. Only the shape of the type info changed.

## Why the branch costs nothing

The compiler decides `if (comptime Field == []const u8)` at compile time, for each field. For `host`, the compiler emits only the print of a string with quotes. For `port`, it emits only the `{any}` print.

The compiler does not compile the other branch at all. Thus the code works when a branch is a type error for the other fields.

## Variations

- **Nested structs:** call the function recursively when `@typeInfo(Field)` is also a struct. Be careful about cycles if types can refer to themselves through pointers.
- **The built-in shortcut:** `{any}` on a full struct already prints a usable result. Write a custom printer when you need control of the format, of the indent, or of the fields that show.
- **Enums and unions:** `{t}` prints tag names directly. Use it together with this recipe for tagged unions.
