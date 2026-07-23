//! title: A Type Function as the Front Door
//! The ORM pattern: hand the library a struct, get a typed API back.

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
