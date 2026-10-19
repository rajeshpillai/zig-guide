//! title: The Adapter Seam
//! One query, three SQL dialects, selected at compile time.

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
