# JSON

> Parse JSON into real types, and write the types back as JSON.

`std.json.parseFromSlice` parses JSON into your own Zig struct. It matches the object keys to the field names. `std.json.Stringify.value` writes a value as JSON to any writer.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Config = struct {
    name: []const u8,
    port: u16,
    debug: bool = false, // a default applies when the field is absent
};

test "parse into a struct" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "name": "server", "port": 8080 }
    ;

    // The parse result owns its allocations. deinit frees all of them.
    const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.value.name, "server"));
    try expect(parsed.value.port == 8080);
    try expect(parsed.value.debug == false);
}

test "unknown fields are rejected by default" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "name": "x", "port": 1, "extra": true }
    ;
    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(Config, gpa, text, .{}),
    );

    // Turn off the check when the payload can have fields that you do
    // not model.
    const lenient = try std.json.parseFromSlice(Config, gpa, text, .{
        .ignore_unknown_fields = true,
    });
    defer lenient.deinit();
    try expect(lenient.value.port == 1);
}

test "dynamic values when the shape is unknown" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{ "a": [1, 2, 3] }
    ,
        .{},
    );
    defer parsed.deinit();

    const array = parsed.value.object.get("a").?.array;
    try expect(array.items.len == 3);
    try expect(array.items[0].integer == 1);
}

test "serialise" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.json.Stringify.value(
        Config{ .name = "out", .port = 99, .debug = true },
        .{},
        &out.writer,
    );
    try expect(std.mem.find(u8, out.written(), "\"port\":99") != null);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.json`)*

## Parse into a struct

`parseFromSlice(T, gpa, text, .{})` puts JSON into your type by the field names of the type. The result owns each allocation that it made:

```zig
const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
defer parsed.deinit();
parsed.value.port;
```

Look at `parsed.value`. The payload is behind the owner, thus one `deinit` frees the full tree. The strings in `parsed.value` point into that arena, thus they become invalid with the arena. If a value must live longer than the parse, duplicate the value.

This design solves a problem that each JSON library has. A parsed document is a tree of small allocations with no single owner. To free the tree correctly, you must walk the tree.

The Zig solution is to allocate the full tree from an arena in the `Parsed(T)` wrapper. Then `deinit` is one call that releases all of the memory at the same time, and it cannot miss a node.

The cost is that the lifetime is all or nothing. If you keep one string from the document, the string does not keep the arena alive. After `deinit`, the arena is gone, and you have a dangling slice. Copy out the values that you need. Or keep the full `Parsed` alive while you use any part of it.

## How the types map to JSON

The compiler decides the mapping from your struct at compile time. The validation comes from this mapping.

| Zig | JSON |
| --- | --- |
| `bool`, integers, floats | the matching primitive |
| `[]const u8` | a string |
| `?T` | the value, or `null`, or absent |
| `[]T` | an array |
| a struct | an object, matched by field name |
| an enum | a string equal to a tag name |
| a tagged union | an object with one key, the tag name |

If a JSON value is too large for an integer field, the result is an error, not a truncation. A string in the place of a number is an error that gives the name of the field.

You write none of these checks. The compiler makes them from the struct definition. Thus the checks always match the struct.

## Absent fields and unknown fields

A field with a default is optional in the input. By default, an **unknown** field is an error:

```zig
error.UnknownField
```

This default finds typos in config files. Turn off the default only when you consume a payload that you do not model fully:

```zig
.{ .ignore_unknown_fields = true }
```

Know the difference between a field that can be absent and a field that can be null:

- `?u16` with no default accepts `null`, but the key must be present.
- `u16 = 8080` accepts an absent key.
- `?u16 = null` accepts the two conditions.

Say which one you mean. If you do not, a config file can get a default value without a report, when the parser must reject the file.

## When you do not know the shape

For a dynamic tree, parse into `std.json.Value`. Then walk `.object`, `.array`,
`.integer`, `.string`, and the other fields. When possible, use a concrete struct. Then the compiler checks the field names, and you get validation.

`std.json.Value` is a tagged union. Thus a walk of the tree is a `switch`, and the exhaustiveness check applies.

A usual compromise is a struct for the parts that are important to you. Give one field the type `std.json.Value` for the part that you pass through without change.

For input that is too large for memory, use `std.json.Scanner`. This is the streaming form. It emits tokens while it reads. Thus a fixed buffer can process a document of many gigabytes. `std.json.Scanner` is more difficult to use. Thus use it only when the document does not fit in memory.

## Write JSON

`std.json.Stringify.value(x, .{}, &writer)` serialises a value to any writer. To make a string, use it with `std.Io.Writer.Allocating`.

Options control the shape of the output. Use `.whitespace = .indent_2` for output that a person will read. Use the default for output that a machine will read.

The function writes to any `std.Io.Writer`. Thus it can serialise directly to a file or a socket, without an intermediate string.
