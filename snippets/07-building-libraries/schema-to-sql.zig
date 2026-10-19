//! title: A Type Function as the Front Door
//! The ORM pattern: give the library a struct, and get a typed API.

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
