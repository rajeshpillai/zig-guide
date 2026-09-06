# Recipe: SQLite From Zig

> Open a database, create a table, insert with a prepared statement, and query, over the C API.

## The problem

You want a real database from Zig, and SQLite is the obvious first one. It is
a C library with no server, so the whole thing is a header and a linked
library. Zig calls C directly, so there is no binding layer to install. The
work is learning SQLite's own open/prepare/bind/step/finalize shape and
translating its integer return codes into Zig errors.

## The plan

1. Import the C API. On current Zig this is a translate-c step in the build,
   imported as `@import("c")`, not the old `@cImport` (see below).
2. `sqlite3_open(":memory:", &db)`. An in-memory database keeps the example
   deterministic and leaves no file behind.
3. `sqlite3_exec` for statements with no results, like `CREATE TABLE`.
4. `sqlite3_prepare_v2` once, then bind, step, and reset per row for inserts.
5. Step a `SELECT` and read columns until it returns `SQLITE_DONE`.

```zig
const std = @import("std");

// @cImport was removed from the language. build.zig translates sqlite3.h with a
// translate-c step and hands it to us under the name "c".
const c = @import("c");

// SQLite reports success as SQLITE_OK; anything else is an error code. Turn
// that into a Zig error so `try` works and nothing is ignored.
fn check(db: ?*c.sqlite3, rc: c_int, ok: c_int) !void {
    if (rc == ok) return;
    std.debug.print("sqlite error: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.Sqlite;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // ":memory:" is a real database that never touches disk, so the run is
    // deterministic and leaves nothing behind.
    var db: ?*c.sqlite3 = null;
    try check(db, c.sqlite3_open(":memory:", &db), c.SQLITE_OK);
    defer _ = c.sqlite3_close(db);
    try out.writeAll("opened :memory:\n");

    // sqlite3_exec runs SQL with no results. err_msg is separate from the
    // return code and must be freed.
    var err_msg: [*c]u8 = null;
    try check(db, c.sqlite3_exec(db,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);",
        null, null, &err_msg), c.SQLITE_OK);
    try out.writeAll("created table users\n");

    // A prepared statement is compiled once, then bound and stepped per row.
    // The ? placeholders keep values out of the SQL text, which is how you
    // avoid injection.
    const users = [_]struct { name: []const u8, email: []const u8 }{
        .{ .name = "Ziggy Stardust", .email = "ziggy@ziglang.in" },
        .{ .name = "Grace Hopper", .email = "grace@ziglang.in" },
        .{ .name = "Alan Turing", .email = "alan@ziglang.in" },
    };

    var insert: ?*c.sqlite3_stmt = null;
    try check(db, c.sqlite3_prepare_v2(db,
        "INSERT INTO users (name, email) VALUES (?, ?);", -1, &insert, null), c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(insert);

    for (users) |u| {
        // Passing null as the destructor is SQLITE_STATIC: the string outlives
        // the step, so SQLite need not copy it.
        _ = c.sqlite3_bind_text(insert, 1, u.name.ptr, @intCast(u.name.len), null);
        _ = c.sqlite3_bind_text(insert, 2, u.email.ptr, @intCast(u.email.len), null);
        try check(db, c.sqlite3_step(insert), c.SQLITE_DONE);
        _ = c.sqlite3_reset(insert); // reuse the compiled statement
    }
    try out.print("inserted {d} rows\n", .{users.len});

    // Stepping a SELECT yields SQLITE_ROW per row until SQLITE_DONE.
    var query: ?*c.sqlite3_stmt = null;
    try check(db, c.sqlite3_prepare_v2(db,
        "SELECT id, name, email FROM users ORDER BY id;", -1, &query, null), c.SQLITE_OK);
    defer _ = c.sqlite3_finalize(query);

    while (c.sqlite3_step(query) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int(query, 0);
        const name = std.mem.span(c.sqlite3_column_text(query, 1));
        const email = std.mem.span(c.sqlite3_column_text(query, 2));
        try out.print("{d} | {s} | {s}\n", .{ id, name, email });
    }

    try out.flush();
}
```

*Links the system libsqlite3, so CI builds and runs it natively. Browser wasm cannot link a C library. (`06-cookbook.sqlite-basic`)*

## `@cImport` is gone; use translate-c

If you are arriving from an older tutorial, the first line will not compile.
Zig used to translate C headers inline with `@cImport`/`@cInclude`. That
builtin was removed. Headers now come through a build-system step,
`b.addTranslateC`, which produces a normal Zig module you import by name. This
guide's `build.zig` does it from a marker on the snippet. It synthesizes a
header that includes `sqlite3.h`, translates it, links `sqlite3`, and hands
the module to the snippet. The payoff is that C imports are cached and
configured like any other dependency rather than re-run on every compile.

## Return codes become errors

Every SQLite call returns an `int`: `SQLITE_OK` for the setup calls,
`SQLITE_ROW` and `SQLITE_DONE` for stepping. Left as integers they are easy to
ignore, which is how C programs skip error handling. The `check` helper
compares the code against the expected one and returns a Zig error otherwise,
so `try` enforces it and `sqlite3_errmsg` explains any failure. This is the
main thing a Zig wrapper adds over the raw API.

## Prepared statements, not string building

The insert uses `?` placeholders and `sqlite3_bind_text`, never string
concatenation. That is the rule that keeps user data out of the SQL grammar,
so a name containing a quote is data, not syntax. Binding with `SQLITE_STATIC`
as the destructor argument is a promise that the string outlives the step, so
SQLite does not copy it. That is true here, because the values are string
literals. `sqlite3_reset` rewinds the compiled statement so the next row
reuses it instead of recompiling.

## Reading columns

Stepping a `SELECT` returns `SQLITE_ROW` once per row. Columns are read by
index and type: `sqlite3_column_int` for the id, `sqlite3_column_text` for the
strings. The text accessor returns a C pointer, so `std.mem.span` turns it
into a Zig slice for printing. The loop ends when `sqlite3_step` returns
`SQLITE_DONE`.

## Variations

- **On disk:** pass a filename instead of `":memory:"` to persist. Everything
  else is identical.
- **Transactions:** wrap a batch of inserts in `BEGIN`/`COMMIT` via
  `sqlite3_exec` to make them atomic and much faster.
- **Other C libraries:** the same `//! link:` mechanism works for any system
  library whose header matches its name; that is how
  [struct memory layout](https://www.ziglang.in/learn/how-to/memory-layout/) and the
  [ABI chapter](https://www.ziglang.in/learn/working-with-c/abi/) connect to the C side.
