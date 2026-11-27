# Recipe: SQLite From Zig

> Open a database, create a table, insert with a prepared statement, and query, through the C API.

Zig calls the C API of SQLite directly. A translate-c build step changes `sqlite3.h` into a module, and the program imports that module as `@import("c")`. The program links `sqlite3`. Zig removed `@cImport`, thus older examples that use it do not compile now.

## The problem

You want a real database from Zig, and SQLite is the usual first database. SQLite is a C library with no server. Thus you need only a header and a linked library.

Zig calls C directly, thus you do not have to install a binding layer. The work is to learn the open/prepare/bind/step/finalize shape of SQLite, and to change its integer return codes into Zig errors.

## The plan

1. Import the C API. On current Zig, this is a translate-c step in the build, imported as `@import("c")`. It is not the old `@cImport` (see below).
2. Call `sqlite3_open(":memory:", &db)`. With an in-memory database, the example is deterministic, and it leaves no file.
3. Use `sqlite3_exec` for statements with no results, for example `CREATE TABLE`.
4. For inserts, call `sqlite3_prepare_v2` one time. Then bind, step and reset for each row.
5. Step a `SELECT`, and read the columns until the step returns `SQLITE_DONE`.

```zig
const std = @import("std");

// Zig removed @cImport from the language. build.zig translates sqlite3.h with a
// translate-c step and gives the result to this file with the name "c".
const c = @import("c");

// SQLite reports success as SQLITE_OK. All other values are error codes.
// Change an error code into a Zig error. Then `try` works, and no code ignores it.
fn check(db: ?*c.sqlite3, rc: c_int, ok: c_int) !void {
    if (rc == ok) return;
    std.debug.print("sqlite error: {s}\n", .{c.sqlite3_errmsg(db)});
    return error.Sqlite;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // ":memory:" is a real database that never uses the disk. Thus the run is
    // deterministic, and it leaves no file.
    var db: ?*c.sqlite3 = null;
    try check(db, c.sqlite3_open(":memory:", &db), c.SQLITE_OK);
    defer _ = c.sqlite3_close(db);
    try out.writeAll("opened :memory:\n");

    // sqlite3_exec runs SQL with no results. err_msg is separate from the
    // return code, and the program must free it.
    var err_msg: [*c]u8 = null;
    try check(db, c.sqlite3_exec(db,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);",
        null, null, &err_msg), c.SQLITE_OK);
    try out.writeAll("created table users\n");

    // SQLite compiles a prepared statement one time. Then the program binds
    // and steps it for each row. The ? placeholders keep values out of the
    // SQL text. Thus they prevent injection.
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
        // A null destructor is SQLITE_STATIC. The string will exist after the
        // step, thus SQLite does not have to copy it.
        _ = c.sqlite3_bind_text(insert, 1, u.name.ptr, @intCast(u.name.len), null);
        _ = c.sqlite3_bind_text(insert, 2, u.email.ptr, @intCast(u.email.len), null);
        try check(db, c.sqlite3_step(insert), c.SQLITE_DONE);
        _ = c.sqlite3_reset(insert); // use the compiled statement again
    }
    try out.print("inserted {d} rows\n", .{users.len});

    // A step of a SELECT gives SQLITE_ROW for each row, until SQLITE_DONE.
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

*The program links the system libsqlite3. Thus CI builds and runs it natively. Browser wasm cannot link a C library. (`06-cookbook.sqlite-basic`)*

## Zig removed `@cImport`: use translate-c

If you come from an older tutorial, the first line does not compile. Before, Zig translated C headers inline with `@cImport` and `@cInclude`. Zig removed that builtin.

Now headers come through a step of the build system, `b.addTranslateC`. This step makes a usual Zig module that you import by name.

The `build.zig` of this guide does this from a marker on the snippet:

1. It makes a header that includes `sqlite3.h`.
2. It translates that header.
3. It links `sqlite3`.
4. It gives the module to the snippet.

As a result, the build caches and configures C imports as it does each other dependency. It does not run them again on each compile.

## Return codes become errors

Each SQLite call returns an `int`. The setup calls return `SQLITE_OK`, and a step returns `SQLITE_ROW` or `SQLITE_DONE`.

If the codes stay integers, it is easy to ignore them. That is how C programs skip error handling.

The `check` helper compares the code with the expected code. If the codes are different, it returns a Zig error. Thus `try` makes the check necessary, and `sqlite3_errmsg` explains each failure. This is the main thing that a Zig wrapper adds to the raw API.

## Prepared statements, not string building

The insert uses `?` placeholders and `sqlite3_bind_text`. It never joins strings. Placeholders keep user data out of the SQL grammar. Thus a name that contains a quote is data, not syntax.

A bind with `SQLITE_STATIC` as the destructor argument is a promise: the string will exist after the step. Thus SQLite does not copy the string. The promise is true here, because the values are string literals.

`sqlite3_reset` returns the compiled statement to its start. Thus the next row uses the same statement, and SQLite does not compile it again.

## Read columns

When you step a `SELECT`, the step returns `SQLITE_ROW` one time for each row. Read the columns by index and type: `sqlite3_column_int` for the id, and `sqlite3_column_text` for the strings.

The text accessor returns a C pointer. Thus `std.mem.span` changes it into a Zig slice for the print. The loop ends when `sqlite3_step` returns `SQLITE_DONE`.

## Variations

- **On disk:** give a filename in place of `":memory:"` to keep the data. All of the other code is the same.
- **Transactions:** put a batch of inserts between `BEGIN` and `COMMIT` with `sqlite3_exec`. Then the inserts are atomic and much faster.
- **Other C libraries:** the same `//! link:` marker works for each system library with a header of the same name. For the layout rules on the C side, see [struct memory layout](https://www.ziglang.in/learn/how-to/memory-layout/) and the [ABI chapter](https://www.ziglang.in/learn/working-with-c/abi/).
