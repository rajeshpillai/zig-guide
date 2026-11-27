# A Query Engine

> The parser asks what. The planner asks how, and the planner does the real work of a database.

Until now, each part of this section got exact instructions. Append this
record. Find this key. Replay this log.

A query is different. `SELECT name FROM people WHERE id = 3` says **what** you
want, and says nothing about how to get it. Some part of the engine must
decide if it examines one row or all rows. The query does not contain that
decision.

Thus a query engine has two halves:

- A parser, which changes text into a structure.
- A **planner**, which changes that structure into a strategy.

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

/// `SELECT <column> FROM <table> WHERE <column> = <value>`. The shape is fixed.
/// Thus the parser checks for each expected token in order. A full expression
/// grammar needs precedence climbing.
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

/// Query planning in a small form. Does a structure already know the answer
/// to the filter, or must the engine examine each row? A real planner asks the
/// same question with statistics. An index that matches most rows is slower
/// than the scan that it replaces.
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
        // `id` is the row number, thus it is the index here. The lookup
        // touches only one row. The method of the lookup does not change that.
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

    // The same first query with no index. The answer is the same, and the
    // work is eight times more.
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

## What the program did

**The same query ran in two ways and gave the same answer.** With an index,
`WHERE id = 3` examined 1 row. Without an index, it examined 8 rows. The result
and the SQL were the same, and the second run did eight times the work. The
query did not change, because the query never said how.

Declarative languages have this design. The same design also causes a problem:
you cannot see the cost when you read the code. For this reason,
all databases have an EXPLAIN command. This program prints two lines: the plan
and the rows examined. When a query is slow, you spend most of your time on
those two lines.

**`WHERE role = engineer` used a scan, because `role` has no index.** The
planner is one comparison: is the filtered column the column of the index? A
real planner asks the same question, and then asks a second question. The
section below describes the second question.

**The parser is a sequence of expectations, not a precedence climb.** The
grammar is fixed. Thus the parse is: expect `SELECT`, take a word, expect
`FROM`, take a word. Compare that with the [recursive descent
parser](https://www.ziglang.in/learn/tiny-lang/parser/) in the language section.

That parser needed
one function for each precedence level, because arithmetic nests. The SQL
`WHERE` clause also nests when it gets `AND`, `OR` and parentheses. At that
point, this parser becomes that parser.

**The parser rejected four malformed queries, and one of them was a
`DELETE`.** The parser has no special rule against a delete. It expected the
word `SELECT` and got a different word. For a grammar of this size, that is a
fair way to reject a query, and that is the meaning of "SQL subset".

## The question that this planner does not ask

Suppose there is an index on `role`. Must `WHERE role = engineer` use it?

Probably not. Three of eight rows match. Thus an index lookup needs three
jumps into the table and a read of the index. A scan is one straight pass that
reads each row in order. Disks and caches strongly prefer the straight pass.

Real planners make this decision with **statistics**:

- Approximately how many rows match this value?
- How large is the table?
- How expensive is a random read, compared with a sequential read?

Because of these statistics, EXPLAIN output has numbers in it, and databases
have a command to refresh the statistics. Also because of statistics, a query
that was fast last month can become slow after the data changes, and no person
changed the query.

An index is faster only *for selective filters*. A planner without statistics
cannot know if a filter is selective.

## Check yourself

The planner selects the index for `WHERE id = 3`, because `id` has an index.
What must the planner know to handle `WHERE id = 3 AND role = engineer`?

The answer: each condition alone can control the plan, and then the other
condition becomes a filter after the lookup. Thus the planner must select one
of two plans:

- Use the `id` index, and check `role` on the one row that it finds.
- Scan, and check both conditions.

The planner must select the first plan, because `id` is more selective.

With two indexes, the choice is more difficult. With a join, the choice becomes
the main problem of query optimisation. The number of possible plans grows
factorially with the number of tables. Thus planners search, and do not make a
list of all plans. Because of the search, the same query can get a different
plan on a different day.

## The end of this section

These five chapters built append-only records, a lock, an index, a write-ahead
log and a query planner. All databases have these parts.

If you prefer to use one of these parts and not to build it, the database
recipes connect to SQLite, Redis and PostgreSQL from Zig. The ORM builds the
layer above them.
