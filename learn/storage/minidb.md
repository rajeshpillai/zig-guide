# A Query Engine

> Parsing asks what. Planning asks how, and that is where a database does its real work.

Everything in this section so far has been told exactly what to do. Append
this record. Look up this key. Replay this log.

A query is different. `SELECT name FROM people WHERE id = 3` says **what** you want and
says nothing about how to get it. Something has to decide whether to look at
one row or all of them, and that decision is not in the query.

So a query engine has two halves. A parser, which turns text into a structure,
and a **planner**, which turns that structure into a strategy.

## The program

```zig
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

/// `SELECT <column> FROM <table> WHERE <column> = <value>`. The shape is fixed,
/// so the parser checks for each expected token in order. A full expression
/// grammar would need precedence climbing.
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

/// Query planning in a small form: can the filter be answered by a
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
        // `id` is the row number, so it acts as the index here. Only one row
        // is touched, and how the lookup finds it does not change that.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`20-storage.minidb`)*

## What just happened

**The same query ran two ways and gave the same answer.** `WHERE id = 3` with
an index examined 1 row. Without one it examined 8. The result and the SQL
were the same, and the second run did eight times the work. Nothing in the query changed, because the
query never said how.

Declarative languages are designed this way. The same design makes them
frustrating: you cannot see the cost by reading the code. For this reason,
every database has an EXPLAIN command. The two lines this program prints,
the plan and the rows examined, are the two lines you spend most of your time
looking at when something is slow.

**`WHERE role = engineer` scanned, because `role` is not indexed.** The planner
is one comparison: is the filtered column the one the index is on? A real
planner asks the same question and then asks a second one, covered below.

**The parser is a sequence of expectations, not a precedence climb.** The
grammar is fixed, so parsing is: expect `SELECT`, take a word, expect `FROM`,
take a word. Compare that with the [recursive descent
parser](https://www.ziglang.in/learn/tiny-lang/parser/) in the language section, which needed one
function per precedence level because arithmetic nests. SQL's `WHERE` clause
nests too, once it grows `AND`, `OR` and parentheses, and at that point this
parser becomes that parser.

**Four malformed queries were rejected, including `DELETE`.** The parser has no
special rule against deleting. It expects the word `SELECT` and got something
else. For a grammar this size, that is a fair way to reject a query, and it is
what "SQL subset" means.

## The question this planner does not ask

Given an index on `role`, should `WHERE role = engineer` use it?

Probably not. Three of eight rows match, so an index lookup means three jumps
into the table plus reading the index, against one straight pass that reads
every row in order. Disks and caches strongly prefer the straight pass.

Real planners decide this with **statistics**: roughly how many rows match
this value, how big is the table, how expensive is a random read against a
sequential one. These statistics are why EXPLAIN output has numbers in it, and
why databases have a command to refresh them. They are also why a query that
was fast last month can become slow after the data changes, without anybody
changing the query.

An index is faster only *for selective filters*, and a planner without
statistics cannot tell whether a filter is selective.

## Check yourself

The planner picks the index for `WHERE id = 3` because `id` is indexed. What
would it have to know to handle `WHERE id = 3 AND role = engineer`?

That either condition alone can drive the plan, and that the other one becomes
a filter applied afterwards. So it must choose: use the `id` index and check
`role` on the single row it finds, or scan and check both. It should pick the
first. The reason is that `id` is more selective.

With two indexes the choice gets harder. With a join it becomes the main
problem of query optimisation: the number of possible plans grows
factorially with the number of tables, so planners search instead of
listing every plan. The search is why the same query can produce a different plan on a
different day.

## Where this section ends

These five chapters built append-only records, a lock, an index, a
write-ahead log and a query planner, the parts every database has.

If you would rather use one of these than build it, the database recipes talk
to SQLite, Redis and PostgreSQL from Zig, and the ORM builds the layer that
sits above them.
