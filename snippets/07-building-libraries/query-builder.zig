//! title: A Typed Query Builder
//! Field names checked while compiling; values bound, never spliced.

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
