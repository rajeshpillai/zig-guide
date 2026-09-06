# A Type Function as the Front Door

> The core move of a Zig library: take the caller's type, return a richer one.

This section teaches library design by building the skeleton of a real one: a
miniature ORM in the style of Elixir's Ecto. Each page distills one pattern
into a snippet small enough to verify; a full ORM adds drivers, pooling, and
migrations around exactly these bones.

## The problem

A library's hardest interface question in Zig is: how does the caller hand you
*their* data shape? Dynamic languages take a dict or use runtime reflection; C
takes void pointers and trusts you. Zig's answer is a function that runs at
compile time, takes a `type`, and returns a new `type` wrapping it.

The ORM version: the caller defines a plain struct, and `Table(User, "users")`
becomes their typed gateway to everything the library can do with it.

## The pattern

1. Accept `comptime T: type` plus whatever configuration belongs beside
   it (the table name).
2. Read `@typeInfo(T)` once, at compile time.
3. Return a struct whose declarations carry everything derived: metadata,
   generated SQL, and eventually query and insert functions.

```zig
const std = @import("std");
const expect = std.testing.expect;

// The library's public API is one function from a type to a type. Callers
// define plain structs; everything else is derived at compile time.
fn Table(comptime T: type, comptime name: []const u8) type {
    const info = @typeInfo(T).@"struct";
    return struct {
        pub const Row = T;
        pub const table_name = name;
        pub const column_count = info.field_names.len;

        // The whole CREATE TABLE statement is assembled while compiling.
        // At runtime it is a plain string constant in the binary.
        pub const create_sql = blk: {
            var sql: []const u8 = "CREATE TABLE " ++ name ++ " (";
            for (info.field_names, info.field_types, 0..) |field, Field, i| {
                if (i > 0) sql = sql ++ ", ";
                sql = sql ++ field ++ " " ++ sqlType(Field);
            }
            break :blk sql ++ ")";
        };

        fn sqlType(comptime Field: type) []const u8 {
            return switch (Field) {
                i32, i64, u32, bool => "INTEGER",
                f32, f64 => "REAL",
                []const u8 => "TEXT",
                else => @compileError("no SQL mapping for " ++ @typeName(Field)),
            };
        }
    };
}

// This is all a caller writes. No registration, no code generation step,
// no runtime reflection: the struct is the schema.
const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
};
const Users = Table(User, "users");

test "the schema compiles to exact SQL" {
    try expect(std.mem.eql(
        u8,
        Users.create_sql,
        "CREATE TABLE users (id INTEGER, name TEXT, active INTEGER)",
    ));
}

test "metadata is comptime-known" {
    try expect(Users.column_count == 3);
    try expect(std.mem.eql(u8, Users.table_name, "users"));
    // Row is the caller's type, unchanged; the API is additive.
    const u = Users.Row{ .id = 1, .name = "ada", .active = true };
    try expect(u.id == 1);
}

test "a second table is a distinct type with its own SQL" {
    const Post = struct {
        id: i64,
        title: []const u8,
        score: f64,
    };
    const Posts = Table(Post, "posts");
    try expect(std.mem.eql(
        u8,
        Posts.create_sql,
        "CREATE TABLE posts (id INTEGER, title TEXT, score REAL)",
    ));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.schema-to-sql`)*

## The SQL exists before the program runs

`create_sql` is assembled in a comptime block with `++` concatenation. By
runtime it is a single string constant in the binary; there is no formatting,
allocation, or reflection left to do. The test comparing it against the exact
expected SQL text is the same style of gate this site runs on every snippet:
character-for-character.

Note where the errors go. A schema field of an unmapped type hits the compile
error in the mapping function. The user of your library learns about it at
their build, with a message you wrote, naming their type. Designing those
messages is part of the API surface.

## The caller's type is not consumed

`Table` wraps; it does not transform. `Users.Row` is the caller's `User`,
unchanged, so their code keeps constructing and passing plain structs. The
additive shape matters: a library that makes callers use *your* struct in
place of theirs infects every function signature they own.

## In a full ORM

This page's `Table` is the seed of the real thing. Grow it by adding
declarations to the returned struct: `insert_sql` with placeholders,
per-column metadata (primary key, nullability) read from sentinel types, and
the query builder from the [next page](https://www.ziglang.in/learn/orm/query-builder/). The public
API never changes shape; it only gains members.
