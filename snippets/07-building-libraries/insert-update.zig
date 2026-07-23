//! title: Writing Rows
//! INSERT and UPDATE derived from the schema, values as a typed array.

const std = @import("std");
const expect = std.testing.expect;

// The driver-facing value type. SQL text and values travel separately;
// this union is the shape of "separately".
const Value = union(enum) {
    int: i64,
    text: []const u8,
    boolean: bool,
};

fn Table(comptime T: type, comptime name: []const u8) type {
    const info = @typeInfo(T).@"struct";
    return struct {
        // "INSERT INTO users (id, name, active) VALUES ($1, $2, $3)"
        pub const insert_sql = blk: {
            var cols: []const u8 = "";
            var params: []const u8 = "";
            for (info.field_names, 0..) |field, i| {
                if (i > 0) {
                    cols = cols ++ ", ";
                    params = params ++ ", ";
                }
                cols = cols ++ field;
                params = params ++ std.fmt.comptimePrint("${d}", .{i + 1});
            }
            break :blk "INSERT INTO " ++ name ++ " (" ++ cols ++ ") VALUES (" ++ params ++ ")";
        };

        // "UPDATE users SET name = $2, active = $3 WHERE id = $1":
        // the first field is the key, by convention stated in the docs.
        pub const update_sql = blk: {
            var sets: []const u8 = "";
            for (info.field_names[1..], 2..) |field, n| {
                if (n > 2) sets = sets ++ ", ";
                sets = sets ++ field ++ std.fmt.comptimePrint(" = ${d}", .{n});
            }
            break :blk "UPDATE " ++ name ++ " SET " ++ sets ++
                " WHERE " ++ info.field_names[0] ++ " = $1";
        };

        // The runtime half: one Value per column, in placeholder order.
        // The inline for resolves every @field while compiling, so this
        // is a fixed sequence of stores at runtime.
        pub fn bind(row: T) [info.field_names.len]Value {
            var values: [info.field_names.len]Value = undefined;
            inline for (info.field_names, 0..) |field, i| {
                values[i] = switch (@TypeOf(@field(row, field))) {
                    i64 => .{ .int = @field(row, field) },
                    []const u8 => .{ .text = @field(row, field) },
                    bool => .{ .boolean = @field(row, field) },
                    else => @compileError("no Value mapping for field " ++ field),
                };
            }
            return values;
        }
    };
}

const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
};
const Users = Table(User, "users");

test "insert statement is derived, not written" {
    try expect(std.mem.eql(
        u8,
        Users.insert_sql,
        "INSERT INTO users (id, name, active) VALUES ($1, $2, $3)",
    ));
}

test "update keys on the first field" {
    try expect(std.mem.eql(
        u8,
        Users.update_sql,
        "UPDATE users SET name = $2, active = $3 WHERE id = $1",
    ));
}

test "bind produces one typed value per placeholder" {
    const values = Users.bind(.{ .id = 7, .name = "ada", .active = true });
    try expect(values.len == 3);
    try expect(values[0].int == 7);
    try expect(std.mem.eql(u8, values[1].text, "ada"));
    try expect(values[2].boolean == true);
}
