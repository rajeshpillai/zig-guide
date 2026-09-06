# Writing Rows

> INSERT and UPDATE statements derived from the schema, with values as a typed array.

## The problem

Reading was the [query builder](https://www.ziglang.in/learn/orm/query-builder/); writing is the
other half. An INSERT must name every column and number every placeholder; an
UPDATE must split key columns from data columns. Writing those statements by
hand, per table, is exactly the repetitive, drift-prone work the schema
already has the information to do.

## The pattern

1. Derive `insert_sql` at compile time: column list and placeholder list
   walked from the same fields, so they cannot disagree in length or
   order.
2. Derive `update_sql` with a stated convention: the first field is the
   key. Conventions a library documents are API; pick them deliberately.
3. Pair each statement with `bind`, which turns a row into an array of
   tagged-union `Value`s, one per placeholder, in the same field order.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.insert-update`)*

## The statement and its values cannot drift

The deep property here: `insert_sql`'s placeholders and `bind`'s output are
generated from one walk over one list of fields. Add a column to the struct
and both change together at the next compile. The classic ORM bug (a statement
with four placeholders fed five values) is not caught here; it is
unrepresentable.

`comptimePrint` does the number formatting during compilation, so even `$3` is
baked into the constant. At runtime, `bind` is a fixed sequence of stores; the
`inline for` leaves no loop behind.

## The Value union is the wire contract

Drivers do not take Zig structs; they take a statement and a list of typed
values. The value union is that list's element type. The compile error in the
mapping arm is the schema's type system meeting the driver's: a field type
with no wire mapping fails the build, naming the field.

## In a full ORM

The draft goes further. It adds returning clauses to inserts, skips
auto-managed columns whose values come from the library rather than the
caller, and marks the key column explicitly instead of by position. All three
are more comptime walking of the same field list.
