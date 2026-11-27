# Read a Type

> Use @typeInfo to list the fields of a struct, an enum and a union, then write a generic diff.

`@typeInfo(T)` returns a description of the type `T`. The description is a usual Zig value of type `std.lang.Type`. It contains the names of the fields, the type of each field and the default values.

The description is comptime-known, thus a function can walk it with `inline for`. The function then has one copy of its body for each field. This is how one function can work with every struct type.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.read-a-type`)*

## The shape of the description

`std.lang.Type` is a tagged union with one variant for each kind of type. To get the description of a struct, take the `@"struct"` variant:

```zig
const info = @typeInfo(T).@"struct";
```

The name has quotes because `struct` is a keyword. The `enum`, `union` and `fn` variants use the same syntax.

For a struct, `info` has three arrays of fields:

- `field_names` holds the name of each field.
- `field_types` holds the type of each field.
- `field_attrs` holds the default value, the alignment and the `comptime` flag of each field.

The three arrays have the same length. Item `i` in each array describes the same field. The fields are in the order of the source file.

## Walk the fields

```zig
inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
    try out.print("  {s}: {s}", .{ name, @typeName(F) });
    if (attrs.defaultValue(F)) |default| { ... }
}
```

A `for` with three arrays walks them together. The loop must be `inline`, because `F` is a type, and a type must be comptime-known in each copy of the body.

`attrs.defaultValue(F)` returns the default value as a `?F`. The result is `null` when the field has no default:

```
Config: 4 fields, 2 declarations
  name: []const u8 = "server"
  port: u16 = 8080
  verbose: bool = false
  retries: u8 (no default)
  pub max_port
  pub isDefaultPort
```

`decl_names` lists the declarations of the type. It lists only `pub` declarations. A declaration without `pub` is not in the list.

[Print Any Struct](https://www.ziglang.in/learn/how-to/struct-printer/) uses the same walk to print a value of any struct type.

## Questions with a yes or no answer

You do not always need the full description. Four builtins answer one question each:

```
@hasField(Config, "port"): true
@hasField(Config, "host"): false
@hasDecl(Config, "isDefaultPort"): true
@FieldType(Config, "port"): u16
```

The answers are comptime-known. Thus a generic function can use them in an `if`, and the compiler removes the branch that is not used.

Use `@hasDecl` to make a method optional. For example, a function can call `value.format(...)` when the type has a `format` method, and use a default output when it does not.

## Enums and unions

The description of an enum has `field_names` and `field_values`:

```
Level: tag type u8
  debug = 0
  info = 1
  warn = 10
  err = 11
```

The source sets `warn = 10`, and `err` follows with 11. The values in the description are the real values, not the position of each tag.

The description of a tagged union has `field_names` and `field_types`. The type of each variant is the type of its payload. A variant without a payload has the type `void`:

```
Shape: 3 variants
  circle: f32
  square: f32
  empty: void
```

## Use the walk: a diff for any struct

```zig
fn diff(out: *Writer, old: anytype, new: @TypeOf(old)) !void {
    const T = @TypeOf(old);
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, F| {
        const a = @field(old, name);
        const b = @field(new, name);
        const same = if (F == []const u8) std.mem.eql(u8, a, b) else a == b;
        ...
    }
}
```

`@field(old, name)` reads the field with the name `name`. The name must be comptime-known. In an `inline for`, each copy of the body has its own comptime-known `name`.

The type of `new` is `@TypeOf(old)`. Thus the two arguments must have the same type, and the compiler rejects a call with two different structs.

Zig does not allow `==` on two slices. Thus the function compares a `[]const u8` field with `std.mem.eql`. The `if` on `F == []const u8` is comptime-known, and each copy of the body contains only one of the two comparisons.

The program changes two fields of a `Config`, and `diff` prints the two changes:

```
diff(before, after):
  name: "server" -> "api"
  verbose: false -> true
```

`port` and `retries` have the same value in the two structs, thus `diff` prints nothing for them. If you add a field to `Config`, `diff` compares the new field too. You do not change `diff`.

## If you used an older version of Zig

Before version 0.17, the description of a struct had one `fields` array. Each item was a struct with a `name`, a `type` and a `default_value_ptr`. A loop was `inline for (info.fields) |f|`, and it read `f.name` and `f.type`.

Now the description has three separate arrays. [Zig 0.17](https://www.ziglang.in/learn/getting-started/zig-0-17/) has a table of the changes for structs, enums and unions.

## Check yourself

A new field `tags: []const []const u8` goes into `Config`. Does `diff` still compile?

No. `F == []const u8` is false for `[]const []const u8`, thus `diff` uses `a == b`, and Zig does not allow `==` on slices. The compiler stops with an error at the line with `a == b`. To repair `diff`, add a branch for this type, or compare the slices item by item.

The next chapter goes in the other direction. It makes a new type from a description.
