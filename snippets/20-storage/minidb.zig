//! title: A Query Engine
//! Parsing asks what. Planning asks how, and that is where the database earns its keep.

const std = @import("std");

const Row = struct { id: []const u8, name: []const u8, role: []const u8 };

const people = [_]Row{
    .{ .id = "1", .name = "alice", .role = "engineer" },
    .{ .id = "2", .name = "bob", .role = "designer" },
    .{ .id = "3", .name = "carol", .role = "engineer" },
    .{ .id = "4", .name = "dave", .role = "manager" },
    .{ .id = "5", .name = "erin", .role = "designer" },
    .{ .id = "6", .name = "frank", .role = "engineer" },
    .{ .id = "7", .name = "grace", .role = "manager" },
    .{ .id = "8", .name = "heidi", .role = "designer" },
};

/// `SELECT <column> FROM <table> WHERE <column> = <value>`. A fixed shape, so
/// the parser is a sequence of expectations rather than the precedence climb a
/// real expression grammar needs.
const Query = struct {
    select: []const u8,
    table: []const u8,
    where_column: []const u8,
    where_value: []const u8,
};

const ParseError = error{ Unexpected, Incomplete };

fn parse(sql: []const u8) ParseError!Query {
    var words = std.mem.tokenizeAny(u8, sql, " \t");

    const expect = struct {
        fn word(it: *std.mem.TokenIterator(u8, .any), want: []const u8) ParseError![]const u8 {
            const got = it.next() orelse return error.Incomplete;
            if (want.len > 0 and !std.ascii.eqlIgnoreCase(got, want)) return error.Unexpected;
            return got;
        }
    };

    _ = try expect.word(&words, "select");
    const select = try expect.word(&words, "");
    _ = try expect.word(&words, "from");
    const table = try expect.word(&words, "");
    _ = try expect.word(&words, "where");
    const column = try expect.word(&words, "");
    _ = try expect.word(&words, "=");
    const value = try expect.word(&words, "");
    if (words.next() != null) return error.Unexpected;

    return .{ .select = select, .table = table, .where_column = column, .where_value = value };
}

fn columnOf(row: Row, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "id")) return row.id;
    if (std.mem.eql(u8, name, "name")) return row.name;
    if (std.mem.eql(u8, name, "role")) return row.role;
    return null;
}

const Plan = enum { index_lookup, table_scan };

/// The whole of query planning, in miniature: can the filter be answered by a
/// structure that already knows the answer, or must every row be looked at?
/// A real planner asks the same question with statistics attached, because an
/// index that matches most rows is slower than the scan it replaces.
fn plan(query: Query, indexed_column: ?[]const u8) Plan {
    const indexed = indexed_column orelse return .table_scan;
    if (std.mem.eql(u8, query.where_column, indexed)) return .index_lookup;
    return .table_scan;
}

const Result = struct { examined: usize, matched: usize };

fn execute(query: Query, indexed_column: ?[]const u8, out: *std.Io.Writer) !Result {
    const chosen = plan(query, indexed_column);
    try out.print("  plan: {s}\n", .{switch (chosen) {
        .index_lookup => "index lookup",
        .table_scan => "table scan",
    }});

    var examined: usize = 0;
    var matched: usize = 0;
    try out.writeAll("  rows: ");

    switch (chosen) {
        // The index is stood in for by the fact that `id` is the row number.
        // What matters is that one row is touched, not how the jump happened.
        .index_lookup => {
            const n = std.fmt.parseInt(usize, query.where_value, 10) catch 0;
            if (n >= 1 and n <= people.len) {
                examined = 1;
                const row = people[n - 1];
                if (columnOf(row, query.select)) |value| {
                    matched = 1;
                    try out.print("{s}", .{value});
                }
            }
        },
        .table_scan => {
            for (people) |row| {
                examined += 1;
                const cell = columnOf(row, query.where_column) orelse continue;
                if (!std.mem.eql(u8, cell, query.where_value)) continue;
                if (columnOf(row, query.select)) |value| {
                    if (matched > 0) try out.writeAll(", ");
                    try out.print("{s}", .{value});
                    matched += 1;
                }
            }
        },
    }

    if (matched == 0) try out.writeAll("(none)");
    try out.print("\n  examined {d} of {d}\n\n", .{ examined, people.len });
    return .{ .examined = examined, .matched = matched };
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const queries = [_][]const u8{
        "SELECT name FROM people WHERE id = 3",
        "SELECT name FROM people WHERE role = engineer",
        "SELECT role FROM people WHERE name = grace",
    };

    try out.writeAll("with an index on id\n\n");
    for (queries) |sql| {
        try out.print("{s}\n", .{sql});
        _ = try execute(try parse(sql), "id", out);
    }

    // The same first query with no index. Same answer, eight times the work.
    try out.writeAll("with no index at all\n\n");
    try out.print("{s}\n", .{queries[0]});
    _ = try execute(try parse(queries[0]), null, out);

    try out.writeAll("rejected\n");
    for ([_][]const u8{
        "SELECT name FROM people",
        "SELECT name FROM people WHERE id 3",
        "DELETE FROM people WHERE id = 3",
        "SELECT name FROM people WHERE id = 3 AND role = x",
    }) |sql| {
        if (parse(sql)) |_| {
            try out.print("  {s} -> accepted, which is wrong\n", .{sql});
        } else |err| {
            try out.print("  {s: <46} {t}\n", .{ sql, err });
        }
    }

    try out.flush();
}
