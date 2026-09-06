# Recipe: A Custom JSON Serializer

> Give a struct a jsonStringify method to rename fields and add computed ones.

## The problem

The default JSON serializer emits your struct exactly as declared: same field
names, same values, nothing more. Often the wire format has to differ. The
field is `is_admin` in Zig but `admin` in the API, or the response needs a
value you compute rather than store. You want that control without
hand-rolling string concatenation and without giving up the checks that keep
the output valid.

Zig's answer is a hook: declare `pub fn jsonStringify` on the type and
`std.json.Stringify` calls it instead of walking the fields.

## The plan

1. Define the struct as usual.
2. Add `pub fn jsonStringify(self: T, jws: anytype) !void`. `jws` is a
   pointer to the write stream.
3. Drive the stream: `beginObject`, then `objectField(name)` and `write(value)`
   per field, then `endObject`.
4. Serialize with `std.json.Stringify.value(x, .{}, writer)`. The hook is
   picked up automatically.

```zig
const std = @import("std");

// Identical fields, no hook: this is what the default serializer emits.
const Plain = struct {
    id: u64,
    name: []const u8,
    is_admin: bool,
    created_at: i64,
};

const User = struct {
    id: u64,
    name: []const u8,
    is_admin: bool,
    created_at: i64,

    // When present, std.json.Stringify calls this instead of walking the
    // fields. `jws` is a *std.json.Stringify write stream. It balances
    // begin/end and quotes strings for you, so the output is always valid.
    pub fn jsonStringify(self: User, jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("user_id"); // rename id
        try jws.write(self.id);

        try jws.objectField("full_name"); // rename name
        try jws.write(self.name);

        try jws.objectField("admin"); // rename is_admin
        try jws.write(self.is_admin);

        // A computed field the struct does not store: whole days since epoch.
        try jws.objectField("epoch_day");
        try jws.write(@divTrunc(self.created_at, std.time.s_per_day));

        try jws.endObject();
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const id = 101;
    const name = "Ziggy Stardust";
    const admin = true;
    const ts = 1672531200; // 2023-01-01T00:00:00Z

    try out.writeAll("default: ");
    try std.json.Stringify.value(
        Plain{ .id = id, .name = name, .is_admin = admin, .created_at = ts },
        .{},
        out,
    );
    try out.writeAll("\n");

    try out.writeAll("custom:  ");
    try std.json.Stringify.value(
        User{ .id = id, .name = name, .is_admin = admin, .created_at = ts },
        .{},
        out,
    );
    try out.writeAll("\n");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.json-custom`)*

## The hook, field by field

`objectField("user_id")` writes the key, and `write(self.id)` writes the value
with normal serialization, including quoting strings and escaping them.
Because you name each key yourself, renaming is just typing a different
string: `is_admin` becomes `admin`, `name` becomes `full_name`. The stream
tracks structure, so if you forget an `endObject` or write a value where a key
belongs, it is a compile-time or runtime error rather than silently malformed
JSON.

## Computed fields

`epoch_day` is not a struct field. The hook computes it from `created_at` and
writes it like any other value. This is the main reason to write a custom
serializer. The output can carry derived data, such as a formatted timestamp,
a signed URL or a total, that you would not want to store on the struct
itself.

## `write` versus `print`

`write(value)` serializes a Zig value as JSON: numbers stay numbers, strings
get quoted. When you need to emit a literal fragment, `jws.print("{d}", .{n})`
writes raw text into the stream, so you are responsible for the quotes and
escaping. Prefer `write` unless you specifically need the raw form; it is the
one that cannot produce invalid output.

## Variations

- **Whitespace:** `std.json.Stringify.value(x, .{ .whitespace = .indent_2 }, w)`
  pretty-prints with two-space indentation.
- **Omitting fields:** a hook can skip a field entirely (write nothing for it),
  which the default serializer cannot do.
- **Unions and enums:** the same `jsonStringify` hook works on tagged unions and
  enums, not just structs.
- **The read side:** parsing back is covered by
  [the JSON config recipe](https://www.ziglang.in/learn/how-to/json-config/), which validates the shape as
  it loads.
