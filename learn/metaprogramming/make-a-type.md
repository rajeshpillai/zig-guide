# Make a Type

> Make integer, struct, enum and tuple types from comptime values, and write a Partial(T) patch type.

The last chapter read the description of a type. This chapter goes in the other direction: a function makes a description, and a builtin changes the description into a new type.

Zig has one builtin for each kind of type that you can make:

- `@Int` makes an integer type.
- `@Struct` makes a struct type.
- `@Enum` makes an enum type.
- `@Union` makes a union type.
- `@Tuple` makes a tuple type.
- `@Pointer` and `@Fn` make pointer and function types.

The program uses four of them.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.make-a-type`)*

## An integer of any width

```zig
const U12 = @Int(.unsigned, 12);
```

`U12` is the same type as `u12`. `@Int` is useful when the width is a calculation, for example one bit for each item in a list:

```
1. u12: 12 bits, 2 bytes, max 4095
```

`@bitSizeOf` gives the 12 bits that the value uses. `@sizeOf` gives 2 bytes, because memory stores a value in whole bytes.

## A struct from another struct

`Partial(T)` has the same fields as `T`, but each field is optional, with a default of `null`. A value of `Partial(Config)` is a patch: it sets only the fields that it wants to change.

```zig
fn Partial(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    var types: [info.field_names.len]type = undefined;
    var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (info.field_types, &types, &attrs) |F, *slot, *attr| {
        slot.* = ?F;
        attr.* = .{ .default_value_ptr = &@as(?F, null) };
    }
    return @Struct(.auto, null, info.field_names, &types, &attrs);
}
```

`Partial` is a usual function with a `comptime` parameter. It runs during compilation because its result is a type. The loop is a usual `for`, not an `inline for`, because the loop body builds arrays and does not need one copy for each field.

`@Struct` takes five arguments:

1. The layout: `.auto`, `.@"extern"` or `.@"packed"`.
2. The backing integer of a packed struct, or `null`.
3. The field names. `Partial` uses the names of `T` without a change.
4. The field types.
5. The field attributes. `Partial` gives each field a default.

`default_value_ptr` is the address of the default value, not the value. `&@as(?F, null)` is the address of a comptime constant. The compiler puts each comptime constant that the program uses into the binary. Thus the address stays valid when the program runs.

The output shows the new fields:

```
2. Partial(Config):
   name: ?[]const u8
   port: ?u16
   verbose: ?bool
```

## Use the new type

```zig
fn apply(base: anytype, patch: Partial(@TypeOf(base))) @TypeOf(base) {
    var result = base;
    inline for (@typeInfo(@TypeOf(base)).@"struct".field_names) |name| {
        if (@field(patch, name)) |value| @field(result, name) = value;
    }
    return result;
}
```

The type of the `patch` parameter is a function call. The compiler calls `Partial` with the type of `base`, and the result is the type of the parameter.

The caller writes `.{ .port = 9090 }`. The compiler knows the type of the parameter, thus the literal becomes a `Partial(Config)`. The other two fields get their default, `null`:

```
   apply(.{ .port = 9090 }): name "server", port 9090, verbose false
```

`Partial(Config)` follows `Config`. If you add a field to `Config`, the patch type gets the same field. You do not change `Partial` or `apply`.

## An enum of the field names

```zig
fn FieldTag(comptime T: type) type {
    const names = @typeInfo(T).@"struct".field_names;
    var values: [names.len]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = i;
    return @Enum(u8, .exhaustive, names, &values);
}
```

`FieldTag(Config)` is an enum with one tag for each field:

```
3. FieldTag(Config): .name .port .verbose
   .port is a number
```

The enum is exhaustive. Thus a `switch` on a `FieldTag(Config)` must have a branch for each tag. If you add a field to `Config`, each `switch` without the new tag stops the build. The compiler then shows you each place that must handle the new field.

The standard library has this function: `std.meta.FieldEnum`. Use the library function in real code. This program writes it to show `@Enum`.

## A tuple from a list of types

```zig
const Pair = @Tuple(&.{ u8, bool });
```

A tuple is a struct with fields that have numbers, not names. `@Tuple` takes a list of types:

```
4. @Tuple: 2 fields, values 7 and true
```

`@Tuple` is useful when a function must build an argument list for another function. `std.meta.ArgsTuple` uses it to make the tuple of argument types for a function.

## If you used an older version of Zig

Older code uses one builtin for all of these types: `@Type`. Its argument was a full `std.builtin.Type` value:

```zig
const U12 = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 12 } });
```

On current Zig, `@Type` does not exist, and the compiler gives the error `invalid builtin function: '@Type'`. Use the builtin for the kind of type that you want. `@Int(.unsigned, 12)` replaces the line above.

`std.meta.Int` and `std.meta.Tuple` are also gone. Zig 0.16.0 already had the `@Int` and `@Tuple` builtins that replace them. [Zig 0.17](https://www.ziglang.in/learn/getting-started/zig-0-17/) lists the other changes to reflection.

## Check yourself

`Partial(Partial(Config))` is a valid type. What is the type of its `port` field?

`??u16`, an optional of an optional. `Partial` adds `?` to each field type, and it does not look at the type first. For this type, `null` and `@as(?u16, null)` are two different values. To prevent this, `Partial` can check `@typeInfo(F) == .optional` and keep a type that is already optional.
