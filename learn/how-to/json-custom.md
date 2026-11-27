# Recipe: A Custom JSON Serializer

> Give a struct a jsonStringify method to rename fields and add computed fields.

To control how Zig writes a struct as JSON, give the struct a `jsonStringify` method. The method controls the write stream with `beginObject`, `objectField`, `write` and `endObject`. Then you can rename a field or add a computed value, and you do not have to build strings.

## The problem

The default JSON serializer writes your struct exactly as you declared it: the same field names, the same values, and nothing more. Often the wire format must be different. For example, the field is `is_admin` in Zig but `admin` in the API. Or the response needs a value that you compute and do not store.

You want that control. You do not want to join strings by hand, and you want to keep the checks that make the output valid.

When the type declares `pub fn jsonStringify`, `std.json.Stringify` calls that function. It does not go through the fields itself.

## The plan

1. Define the struct as usual.
2. Add `pub fn jsonStringify(self: T, jws: anytype) !void`. `jws` is a pointer to the write stream.
3. Control the stream: call `beginObject`, then `objectField(name)` and `write(value)` for each field, then `endObject`.
4. Serialize with `std.json.Stringify.value(x, .{}, writer)`. The serializer finds the hook automatically.

```zig
const std = @import("std");

// The same fields, and no hook: the default serializer writes this struct.
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

    // If this function exists, std.json.Stringify calls it, and does not go
    // through the fields. `jws` is a *std.json.Stringify write stream. It
    // matches each begin to an end and puts quotes on strings for you. Thus
    // the output is always valid.
    pub fn jsonStringify(self: User, jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("user_id"); // rename id
        try jws.write(self.id);

        try jws.objectField("full_name"); // rename name
        try jws.write(self.name);

        try jws.objectField("admin"); // rename is_admin
        try jws.write(self.is_admin);

        // A computed field that the struct does not store: whole days since epoch.
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

## The hook, one field at a time

`objectField("user_id")` writes the key. `write(self.id)` writes the value with the usual serialization. For a string, that includes the quotes and the escape characters.

You give the name of each key yourself. Thus, to rename a field, type a different string: `is_admin` becomes `admin`, and `name` becomes `full_name`.

The stream records the structure. You can forget an `endObject`, or write a value where a key must be. Then you get an error at compile time or at runtime. The stream does not silently write JSON that is not valid.

## Computed fields

`epoch_day` is not a struct field. The hook computes the value from `created_at` and writes it as usual.

This is the main reason to write a custom serializer. The output can contain derived data that you do not want to store on the struct. Examples are a formatted timestamp, a signed URL or a total.

## `write` and `print`

`write(value)` serializes a Zig value as JSON. Numbers stay numbers, and strings get quotes.

To write a literal part of the text, use `jws.print("{d}", .{n})`. This function writes raw text into the stream. Thus you must supply the quotes and the escape characters yourself.

Use `write` unless you specifically need the raw form. `write` cannot make output that is not valid.

## Variations

- **Whitespace:** `std.json.Stringify.value(x, .{ .whitespace = .indent_2 }, w)` writes the JSON with an indent of two spaces.
- **Omit fields:** a hook can omit a field fully, because it can write nothing for that field. The default serializer cannot do this.
- **Unions and enums:** the same `jsonStringify` hook works on tagged unions and enums, not only on structs.
- **The read side:** [the JSON config recipe](https://www.ziglang.in/learn/how-to/json-config/) shows how to parse the JSON back. That recipe validates the shape when it loads the config.
