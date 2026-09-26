# The Adapter Seam

> One query renderer, several SQL dialects, resolved at compile time.

A Zig ORM can support several SQL dialects without interfaces or a
vtable. Each dialect is a struct of `pub` declarations, the renderer
takes it as a `comptime Dialect: type` parameter, and the choice is made
at compile time with no runtime dispatch.

## The problem

PostgreSQL numbers its placeholders (`$1`), SQLite uses positional question
marks, MySQL quotes identifiers with backticks. An ORM that supports more than
one database needs a seam: one place in the code where dialect differences
live, and no other place. The
query builder above the seam should not know which database exists below it.

In a language with interfaces you would define `IDialect`. Zig's answer is
structural: a dialect is any type with the right declarations, passed as a
`comptime` parameter.

## The pattern

1. Define each dialect as a small struct of `pub` declarations: a
   `placeholder` writer and a `quote` string.
2. The renderer takes `comptime Dialect: type` and calls
   `Dialect.placeholder(...)` where the difference matters.
3. Each dialect instantiates its own copy of the renderer, with the calls
   inlined.

```zig
const std = @import("std");
const expect = std.testing.expect;

// A dialect is any type with these declarations. It does not implement an
// interface or use a vtable. The requirement is structural: a missing
// declaration is a compile error at the call site that used it.
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
    pub const quote = "`"; // differs from the other dialects
};

// The renderer takes the dialect as a comptime parameter. Each dialect
// instantiates its own copy of this function with the calls inlined.
// Nothing is dispatched at runtime.
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

Nothing declares "Mysql implements Dialect". The requirement is exactly the
set of declarations the renderer touches, and a dialect missing one fails to
compile at the line that needed it. The standard library uses the same
contract style for its `Io` implementations, and the [repo's
driver](https://www.ziglang.in/learn/orm/repo/) uses it for databases.

The three tests are the seam's specification: the same call produces three
exact SQL strings, and the only differences between them are the placeholders
and the quoting. When a new difference appears (say,
`LIMIT` syntax), it becomes a new declaration, and every dialect must supply
it or fail to build.

## When to use comptime dispatch, and when not

Comptime dialect selection means one binary supports the dialects it was
compiled with. That trade-off suits an ORM, because an application knows
its database. If users must choose a dialect from a config file at startup,
you need runtime dispatch: a tagged union over the dialects, or a vtable like
`std.mem.Allocator`. Start with comptime. If you later change the dispatch,
the seam stays in the same place.

## In a full ORM

The draft's adapters carry more than syntax: connection setup, the wire
protocol (libpq for PostgreSQL, embedded C for SQLite), and type encoding live
behind the same seam. The dialect surface grows, but all of it stays behind
the seam.
