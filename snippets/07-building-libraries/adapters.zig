//! title: The Adapter Seam
//! One query, two SQL dialects, chosen at compile time.

const std = @import("std");
const expect = std.testing.expect;

// A dialect is any type with these declarations. There is no interface
// to implement and no vtable; the requirement is structural, and a
// missing declaration is a compile error at the call site that used it.
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
    pub const quote = "`"; // the one that is different
};

// The renderer takes the dialect as a comptime parameter. Each dialect
// instantiates its own copy of this function with the calls inlined;
// there is no dispatch at runtime.
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
