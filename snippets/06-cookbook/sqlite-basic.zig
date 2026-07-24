//! title: SQLite From Zig
//! link: sqlite3
//! Open, create, insert with a prepared statement, and query. In-memory DB.

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
