# Write Rows

> INSERT and UPDATE statements derived from the schema, with the values in a typed array.

A Zig ORM can derive its INSERT and UPDATE statements from the schema struct
at compile time. The same walk over the fields also builds the values, as an
array of tagged-union `Value`s. Thus the statement and its values always have
the same length and the same order.

## The problem

The [query builder](https://www.ziglang.in/learn/orm/query-builder/) reads rows. Writes are the other
half. An INSERT must name each column and give a number to each placeholder. An
UPDATE must separate the key columns from the data columns.

If you write those statements by hand for each table, the work repeats, and the
statements easily become out of date. The schema already has the data to make
them.

## The pattern

1. Derive `insert_sql` at compile time. Make the column list and the
   placeholder list from the same fields.
2. Derive `update_sql` with a stated convention: the first field is the key. A
   convention that a library documents is part of its API, so select it
   carefully.
3. Pair each statement with `bind`. `bind` changes a row into an array of
   tagged-union `Value`s, one for each placeholder, in the same field order.

```zig
const std = @import("std");
const expect = std.testing.expect;

// The value type that the driver gets. The SQL text and the values go to
// the driver separately, and the values have the form of this union.
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
        // the first field is the key, by a convention in the docs.
        pub const update_sql = blk: {
            var sets: []const u8 = "";
            for (info.field_names[1..], 2..) |field, n| {
                if (n > 2) sets = sets ++ ", ";
                sets = sets ++ field ++ std.fmt.comptimePrint(" = ${d}", .{n});
            }
            break :blk "UPDATE " ++ name ++ " SET " ++ sets ++
                " WHERE " ++ info.field_names[0] ++ " = $1";
        };

        // The runtime half: one Value for each column, in placeholder order.
        // The inline for resolves each @field at compile time. Thus, at
        // runtime, this loop is a fixed sequence of stores.
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

## The statement and its values always agree

The placeholders of `insert_sql` and the output of `bind` come from one walk
over one list of fields. If you add a column to the struct, both change
together at the next compile.

A common ORM bug is a statement with four placeholders that gets five values.
Here you cannot write that bug, because both come from one list.

`comptimePrint` formats the numbers during compilation. Thus even `$3` is in
the constant. At runtime, `bind` is a fixed sequence of stores. The
`inline for` leaves no loop in the binary.

## The Value union is the wire contract

Drivers do not take Zig structs. They take a statement and a list of typed
values. The value union is the element type of that list.

The compile error in the mapping arm checks the types of the schema against
the types of the driver. If a field type has no wire mapping, the build fails,
and the error names the field.

## In a full ORM

The draft does more:

- It adds `RETURNING` clauses to inserts.
- It skips auto-managed columns. The library gives the values of these columns,
  not the caller.
- It marks the key column explicitly, not by position.

All three changes walk the same field list at compile time.
