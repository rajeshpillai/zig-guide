# A Typed Query Builder

> Compile-time field checks and output that stops injection, with no allocator.

A typed query builder in Zig takes columns as `std.meta.FieldEnum(T)`. Thus a
misspelled column is a compile error. The builder writes values as numbered
placeholders (`$1`, `$2`), and the values never touch the SQL text. The builder
is a plain value, and you can chain its calls without an allocator.

## The problem

Each database library has the same two failure modes:

- A query names a column that does not exist. You find the error at runtime,
  in production, as a database error.
- A value goes into the SQL string directly. You find the error as an
  injection.

A Zig library can prevent both at the type level, and the code for this is
small.

## The pattern

1. `std.meta.FieldEnum(T)` changes the field names of the schema struct into an
   enum. A filter takes that enum. Thus `.where(.emial, .eq)` is a compile
   error, and the error shows the misspelled name.
2. The builder is a plain value. `where` copies the builder, appends to a
   bounded array, and returns the copy. Thus the caller can make many queries
   from one base query.
3. `render` writes numbered placeholders, and the values go to the driver
   separately.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn Query(comptime T: type) type {
    return struct {
        // FieldEnum changes the fields of the struct into an enum. Thus a
        // filter on a misspelled column is a compile error, not an SQL error
        // at runtime.
        pub const Field = std.meta.FieldEnum(T);
        pub const Op = enum {
            eq,
            lt,
            gt,

            fn sql(op: Op) []const u8 {
                return switch (op) {
                    .eq => " = ",
                    .lt => " < ",
                    .gt => " > ",
                };
            }
        };

        const Filter = struct { field: Field, op: Op };

        table: []const u8,
        // The builder has a bounded array, and it is a value, not a pointer.
        // Thus you can chain its calls without an allocator. The limit of
        // eight filters is a choice. The library makes that choice and
        // documents it.
        filters: [8]Filter = undefined,
        filter_count: usize = 0,

        pub fn where(q: @This(), field: Field, op: Op) @This() {
            var next = q;
            next.filters[next.filter_count] = .{ .field = field, .op = op };
            next.filter_count += 1;
            return next;
        }

        // Values never go into the SQL text. The statement holds numbered
        // placeholders, and the values go to the driver separately. Values
        // outside the SQL text make injection impossible.
        pub fn render(q: @This(), w: *std.Io.Writer) !void {
            try w.print("SELECT * FROM {s}", .{q.table});
            for (q.filters[0..q.filter_count], 1..) |f, n| {
                try w.writeAll(if (n == 1) " WHERE " else " AND ");
                try w.print("{t}{s}${d}", .{ f.field, f.op.sql(), n });
            }
        }
    };
}

const User = struct {
    id: i64,
    name: []const u8,
    age: u8,
};

fn rendered(q: anytype, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try q.render(&w);
    return w.buffered();
}

test "no filters" {
    var buf: [128]u8 = undefined;
    const q = Query(User){ .table = "users" };
    try expect(std.mem.eql(u8, try rendered(q, &buf), "SELECT * FROM users"));
}

test "filters chain, placeholders number themselves" {
    var buf: [128]u8 = undefined;
    const q = (Query(User){ .table = "users" })
        .where(.name, .eq)
        .where(.age, .gt);
    try expect(std.mem.eql(
        u8,
        try rendered(q, &buf),
        "SELECT * FROM users WHERE name = $1 AND age > $2",
    ));
}

test "the field argument is an enum, not a string" {
    // `.email` does not compile, because User has no field with that name.
    // The check costs nothing at runtime, because the enum exists only at
    // compile time.
    const q = (Query(User){ .table = "users" }).where(.id, .lt);
    try expect(q.filter_count == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.query-builder`)*

## What the enum gives you

The `Field` enum exists only at compile time. At runtime, a filter is an
integer tag. `{t}` formats the tag name back into SQL. Thus the enum checks the
column and also supplies its name. That gives three properties:

- A typo does not compile.
- The check costs nothing at runtime.
- No string table must stay the same as the schema.

The same method works in code that is not an ORM. A library can accept "one of
the fields of this struct" as an argument, for example a sorter, a serializer
or a diff tool. That library can take `FieldEnum(T)` in place of a string, and
move the failure to compile time.

## Why the builder is by-value

`where` returns a changed copy. Thus, in practice, the builder is immutable.
When one call site adds its filters, it cannot corrupt a shared base query.

The bounded array keeps the copy cheap and the API free of allocators. The cost
is a fixed capacity. State that trade-off in the documentation of your library
as a design decision. Do not hide it as an implementation detail.

## In a full ORM

The real builder adds operators, `ORDER BY`, joins and an `insert` path. It
pairs each placeholder with a typed value list for the driver.

This section comes from a draft. The draft writes PostgreSQL and SQLite
dialects from the same builder. The dialect switch is in `render`, in the same
place as the SQL format code of this snippet.
