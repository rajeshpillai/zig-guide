# JSON

> Parsing into real types, and back out again.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Config = struct {
    name: []const u8,
    port: u16,
    debug: bool = false, // defaults cover missing fields
};

test "parse into a struct" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "name": "server", "port": 8080 }
    ;

    // The parse result owns its allocations; deinit frees them all at once.
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

    // Opt out when the payload may carry fields you do not model.
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

## Parsing into a struct

`parseFromSlice(T, gpa, text, .{})` maps JSON onto your type using its field
names. The result owns every allocation it made:

```zig
const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
defer parsed.deinit();
parsed.value.port;
```

Note `parsed.value`: the payload lives behind the owner so a single `deinit`
frees the whole tree. Strings in `parsed.value` point into that arena, so they
die with it; duplicate anything you need to outlive the parse.

That arrangement is worth pausing on, because it is the answer to a problem
every JSON library has. A parsed document is a tree of small allocations with
no single owner, and freeing it correctly means walking it. Zig's answer is to
allocate the whole tree from an arena held by the `Parsed(T)` wrapper.
`deinit` is then one call that releases everything at once and cannot miss a
node.

The cost is that the lifetime is all or nothing. Holding onto one string from
the document keeps nothing alive, because the arena is gone after `deinit`; it
leaves you with a dangling slice. Copy what you need out, or keep the whole
`Parsed` alive for as long as any part of it is in use.

## How types map

The mapping is decided at compile time from your struct, which is where the
validation comes from.

| Zig | JSON |
| --- | --- |
| `bool`, integers, floats | the matching primitive |
| `[]const u8` | a string |
| `?T` | the value, or `null`, or absent |
| `[]T` | an array |
| a struct | an object, matched by field name |
| an enum | a string equal to a tag name |
| a tagged union | an object with one key, the tag name |

An integer field given a JSON value that does not fit is an error rather than
a truncation. A string given where a number was expected is an error naming
the field. None of that had to be written, and none of it can drift from the
struct, because the struct is the schema.

## Missing and unknown fields

A field with a default is optional in the input. An **unknown** field is an
error by default:

```zig
error.UnknownField
```

That default is the right one: it catches typos in config files. Opt out
deliberately when consuming a payload you do not fully model:

```zig
.{ .ignore_unknown_fields = true }
```

The distinction to keep straight is between a field that may be absent and a
field that may be null. `?u16` with no default accepts `null` but still
requires the key to be present. `u16 = 8080` accepts the key being missing.
`?u16 = null` accepts both. Say which one you mean, because a config file
silently taking a default it should have rejected is the failure this system
exists to prevent.

## When the shape is not known

Parse into `std.json.Value` for a dynamic tree, then walk `.object`, `.array`,
`.integer`, `.string`, and friends. Prefer a concrete struct where you can:
you get validation and field names checked at compile time.

`std.json.Value` is a tagged union, so walking it is a `switch` and the
exhaustiveness check applies. The usual middle ground is to model the parts
you care about as a struct and give one field the type `std.json.Value` for
the part you are passing through untouched.

For input too large to hold in memory, `std.json.Scanner` is the streaming
form: it emits tokens as it reads, so a multi-gigabyte document can be
processed with a fixed buffer. It is more work to use and the right answer
only when the document genuinely does not fit.

## Writing

`std.json.Stringify.value(x, .{}, &writer)` serialises to any writer. Pair it
with `std.Io.Writer.Allocating` to produce a string.

Options control the shape of the output: `.whitespace = .indent_2` for
something a person will read, the default for something a machine will. Since
it writes to any `std.Io.Writer`, serialising straight to a file or a socket
costs no intermediate string.
