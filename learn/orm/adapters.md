# The Adapter Seam

> One query renderer, several SQL dialects, resolved at compile time.

A Zig ORM can support several SQL dialects without interfaces or a vtable.
Each dialect is a struct of `pub` declarations. The renderer takes the dialect
as a `comptime Dialect: type` parameter. The compiler makes the selection, so
no dispatch occurs at runtime.

## The problem

The SQL dialects are different:

- PostgreSQL gives numbers to its placeholders (`$1`).
- SQLite uses positional question marks.
- MySQL puts identifiers in backticks.

An ORM that supports more than one database needs a seam. The seam is the one
place in the code that holds the dialect differences, and no other place holds
them. The query builder above the seam must not know which database is below
it.

In a language with interfaces, you define `IDialect`. The Zig answer is
structural. A dialect is any type with the correct declarations, and the code
gives it as a `comptime` parameter.

## The pattern

1. Define each dialect as a small struct of `pub` declarations: a
   `placeholder` writer and a `quote` string.
2. The renderer takes `comptime Dialect: type`. It calls
   `Dialect.placeholder(...)` where the difference is important.
3. Each dialect makes its own copy of the renderer, with the calls inlined.

```zig
const std = @import("std");
const expect = std.testing.expect;

// A dialect is any type with these declarations. It does not implement an
// interface or use a vtable. The requirement is structural. If a dialect does
// not have a declaration, the call site that uses it gives a compile error.
const Postgres = struct {
    pub fn placeholder(w: *std.Io.Writer, n: usize) !void {
        try w.print("${d}", .{n});
    }
    pub const quote = "\"";
};

const Sqlite = struct {
    pub fn placeholder(w: *std.Io.Writer, _: usize) !void {
        try w.writeAll("?");
    }
    pub const quote = "\"";
};

const Mysql = struct {
    pub fn placeholder(w: *std.Io.Writer, _: usize) !void {
        try w.writeAll("?");
    }
    pub const quote = "`"; // different from the other dialects
};

// The renderer takes the dialect as a comptime parameter. Each dialect
// makes its own copy of this function, with the calls inlined. No dispatch
// occurs at runtime.
fn renderSelect(
    comptime Dialect: type,
    w: *std.Io.Writer,
    table: []const u8,
    filters: []const []const u8,
) !void {
    const q = Dialect.quote;
    try w.print("SELECT * FROM {s}{s}{s}", .{ q, table, q });
    for (filters, 1..) |field, n| {
        try w.writeAll(if (n == 1) " WHERE " else " AND ");
        try w.print("{s} = ", .{field});
        try Dialect.placeholder(w, n);
    }
}

fn rendered(comptime Dialect: type, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try renderSelect(Dialect, &w, "users", &.{ "name", "age" });
    return w.buffered();
}

test "postgres numbers its placeholders" {
    var buf: [128]u8 = undefined;
    try expect(std.mem.eql(
        u8,
        try rendered(Postgres, &buf),
        "SELECT * FROM \"users\" WHERE name = $1 AND age = $2",
    ));
}

test "sqlite uses positional question marks" {
    var buf: [128]u8 = undefined;
    try expect(std.mem.eql(
        u8,
        try rendered(Sqlite, &buf),
        "SELECT * FROM \"users\" WHERE name = ? AND age = ?",
    ));
}

test "mysql differs only where it differs" {
    var buf: [128]u8 = undefined;
    try expect(std.mem.eql(
        u8,
        try rendered(Mysql, &buf),
        "SELECT * FROM `users` WHERE name = ? AND age = ?",
    ));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.adapters`)*

## Requirements are structural, and errors are precise

No code declares "Mysql implements Dialect". The requirement is exactly the set
of declarations that the renderer touches. If a dialect does not have one of
those declarations, the compile fails at the line that needed it.

The standard library uses the same contract style for its `Io`
implementations. The [driver of the repo](https://www.ziglang.in/learn/orm/repo/) uses it for
databases.

The three tests are the specification of the seam. The same call makes three
exact SQL strings. The only differences between them are the placeholders and
the quotes. When a new difference occurs (for example, the `LIMIT` syntax), it
becomes a new declaration. Each dialect must supply the declaration, or the
build fails.

## When to use comptime dispatch, and when not

With a dialect selected at compile time, one binary supports only the dialects
that it compiled with. That trade-off is good for an ORM, because an
application knows its database.

If users must select a dialect from a config file at startup, you need dispatch
at runtime. Use a tagged union over the dialects, or a vtable as in
`std.mem.Allocator`. Start with comptime. If you change the dispatch later, the
seam stays in the same place.

## In a full ORM

The adapters of the draft hold more than syntax. The same seam also holds these
parts:

- The connection setup.
- The wire protocol (libpq for PostgreSQL, embedded C for SQLite).
- The type encoding.

The surface of the dialect becomes larger, but all of it stays behind the seam.
