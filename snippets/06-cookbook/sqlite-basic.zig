//! title: SQLite From Zig
//! link: sqlite3
//! Open, create, insert with a prepared statement, and query. The database is in memory.

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
