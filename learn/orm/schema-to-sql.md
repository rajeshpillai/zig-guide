# A Type Function as the Front Door

> The central pattern of a Zig library: take the type of the caller, and return a richer type.

These pages build a small ORM in the style of Ecto from Elixir. Each page takes
one pattern and makes it into a snippet that is small enough to verify. A full
ORM adds drivers, pools and migrations around these same basic parts.

## The problem

A Zig library has a difficult interface question: how does the caller give you
*the data shape of the caller*? Dynamic languages take a dict or use reflection
at runtime. C takes void pointers and trusts you.

The Zig answer is a function that runs at compile time. The function takes a
`type` and returns a new `type` that wraps the first type.

In the ORM, the caller defines a plain struct. Then `Table(User, "users")`
becomes the typed gateway of the caller to all the operations that the library
can do with that struct.

## The pattern

1. Accept `comptime T: type`, and the configuration that goes with it (the
   table name).
2. Read `@typeInfo(T)` one time, at compile time.
3. Return a struct whose declarations hold all the derived data: metadata,
   generated SQL, and later the query and insert functions.

```zig
const std = @import("std");
const expect = std.testing.expect;

// The public API of the library is one function from a type to a type.
// Callers define plain structs. The compiler derives all other parts.
fn Table(comptime T: type, comptime name: []const u8) type {
    const info = @typeInfo(T).@"struct";
    return struct {
        pub const Row = T;
        pub const table_name = name;
        pub const column_count = info.field_names.len;

        // The compiler makes the full CREATE TABLE statement. At runtime,
        // the statement is a plain string constant in the binary.
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

// A caller writes only this struct. The caller does not register
// anything, run a code generator or use reflection at runtime. The struct
// is the schema.
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
    // Row is the type of the caller, with no change. The library only adds
    // new declarations next to it.
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

A comptime block makes `create_sql` with `++` concatenation. At runtime,
`create_sql` is one string constant in the binary. No formatting, allocation
or reflection remains to do.

The test compares `create_sql` with the exact expected SQL text. This site
uses the same type of gate on each snippet: a comparison character by
character.

Look at the location of the errors. If a schema field has a type that the
library cannot map, the mapping function gives a compile error. The user of
your library sees the error at build time. The message is a message that you
wrote, and it names the type of the user. These messages are part of your
API, so design them.

## The type of the caller does not change

`Table` wraps the type of the caller and does not change it. `Users.Row` is the
`User` of the caller, with no change. Thus the code of the caller continues to
make and pass plain structs.

This is important. Some libraries make callers use *the library struct* in place
of their own struct. Then that struct goes into each function signature that
the callers own.

## In a full ORM

The `Table` on this page is the start of the real one. To make it larger, add
declarations to the returned struct:

- `insert_sql` with placeholders.
- Metadata for each column (primary key, nullability), read from sentinel types.
- The query builder from the [next page](https://www.ziglang.in/learn/orm/query-builder/).

The current members of the public API do not change. The API only gets new
members.
