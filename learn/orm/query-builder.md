# A Typed Query Builder

> Compile-time field checking and injection-proof rendering, with no allocator.

## The problem

Every database library faces the same two failure modes. Queries that
reference columns which do not exist, found at runtime in production as a
database error. And string-spliced values, found as an injection. A Zig
library can rule out both at the type level, and the machinery is smaller than
you would guess.

## The pattern

1. `std.meta.FieldEnum(T)` turns the schema struct's field names into an
   enum. A filter takes that enum, so `.where(.emial, .eq)` is a compile
   error with the misspelling in it.
2. The builder is a plain value. `where` copies it, appends to a bounded
   array, and returns the copy; chaining needs no allocator and the
   caller can fork a base query freely.
3. `render` writes numbered placeholders (`$1`, `$2`); values never touch
   the SQL text. They travel to the driver separately.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn Query(comptime T: type) type {
    return struct {
        // FieldEnum turns the struct's fields into an enum, so a filter on
        // a misspelled column is a compile error, not a runtime SQL error.
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
        // Bounded and by-value, so the builder can be chained without an
        // allocator. Eight filters is a policy, not a law; it is the
        // library's choice to make and document.
        filters: [8]Filter = undefined,
        filter_count: usize = 0,

        pub fn where(q: @This(), field: Field, op: Op) @This() {
            var next = q;
            next.filters[next.filter_count] = .{ .field = field, .op = op };
            next.filter_count += 1;
            return next;
        }

        // Values never enter the SQL text. The statement carries numbered
        // placeholders; values travel separately to the driver. That single
        // decision is what makes injection impossible by construction.
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
    // `.email` would not compile: User has no such field. The check costs
    // nothing at runtime because the enum exists only at compile time.
    const q = (Query(User){ .table = "users" }).where(.id, .lt);
    try expect(q.filter_count == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.query-builder`)*

## What the enum buys

The `Field` enum exists only at compile time; by runtime a filter is an
integer tag. `{t}` formats the tag name back into SQL, so the enum is
simultaneously the validator and the column-name source. One decision, three
properties: typo-proof, zero-cost, and no string table to keep in sync with
the schema.

The same trick generalizes beyond ORMs. Any library that accepts "one of this
struct's fields" as an argument (sorters, serializers, diff tools) can take
`FieldEnum(T)` instead of a string and move the failure to compile time.

## Why the builder is by-value

`where` returning a modified copy makes the builder immutable in practice: a
shared base query cannot be corrupted by one call site adding its filters. The
bounded array keeps the copy cheap and the API allocator-free, at the cost of
a fixed capacity. That trade is worth stating in your library's documentation
as a design decision, not hiding as an implementation detail.

## In a full ORM

The real builder grows operators, `ORDER BY`, joins, and an `insert` path, and
pairs each placeholder with a typed value list for the driver. The draft this
section distills from renders to PostgreSQL and SQLite dialects from the same
builder; the dialect switch lives in `render`, exactly where this snippet's
SQL formatting lives.
