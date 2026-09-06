# make

> A dependency graph, a topological order, and a comparison of timestamps.

`make` has a reputation for being a language with strange rules about tabs. It
is not. Strip the syntax away and what is left is two ideas, both small, and
both worth building once so the tool stops being mysterious.

The first: **the targets form a graph.** `app` needs `main.o` and `util.o`,
each of which needs its `.c` file. Building in the right order means visiting
a node only after everything it depends on, which is a topological sort.

The second: **a timestamp decides whether work happens.** A target is stale if
anything it depends on is newer than it is. That single comparison is the
entire reason `make` is faster than a shell script that rebuilds everything.

## The program

```zig
const std = @import("std");

const Rule = struct {
    target: []const u8,
    needs: []const []const u8,
    /// Stands in for the file's mtime. Higher is newer; 0 means absent.
    stamp: u64,
};

/// Visit dependencies before the thing that depends on them, and refuse to
/// loop. This is the whole of make's ordering, and the `visiting` flag is what
/// turns an infinite recursion into an error you can report.
fn order(
    rules: []const Rule,
    target: []const u8,
    state: []u8,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const idx = indexOf(rules, target) orelse return; // a source file, not a rule
    switch (state[idx]) {
        2 => return, // already scheduled
        1 => return error.CircularDependency,
        else => {},
    }
    state[idx] = 1;
    for (rules[idx].needs) |need| try order(rules, need, state, out, allocator);
    state[idx] = 2;
    try out.append(allocator, target);
}

fn indexOf(rules: []const Rule, name: []const u8) ?usize {
    for (rules, 0..) |rule, i| {
        if (std.mem.eql(u8, rule.target, name)) return i;
    }
    return null;
}

fn stampOf(rules: []const Rule, name: []const u8, sources: []const Rule) u64 {
    if (indexOf(rules, name)) |i| return rules[i].stamp;
    if (indexOf(sources, name)) |i| return sources[i].stamp;
    return 0;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var storage: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fba.allocator();

    const sources = [_]Rule{
        .{ .target = "main.c", .needs = &.{}, .stamp = 30 },
        .{ .target = "util.c", .needs = &.{}, .stamp = 10 },
    };
    const rules = [_]Rule{
        .{ .target = "main.o", .needs = &.{"main.c"}, .stamp = 20 },
        .{ .target = "util.o", .needs = &.{"util.c"}, .stamp = 20 },
        .{ .target = "app", .needs = &.{ "main.o", "util.o" }, .stamp = 25 },
    };

    // `@splat`, not the `**` repeat operator, which the language dropped.
    var state: [rules.len]u8 = @splat(0);
    var scheduled: std.ArrayList([]const u8) = .empty;
    defer scheduled.deinit(allocator);
    try order(&rules, "app", &state, &scheduled, allocator);

    try out.writeAll("build order:\n");
    for (scheduled.items) |target| try out.print("  {s}\n", .{target});

    // A target is stale when anything it depends on is newer than it is. That
    // one comparison is the entire reason make is faster than a shell script.
    try out.writeAll("\nwhat actually needs rebuilding:\n");
    for (scheduled.items) |target| {
        const i = indexOf(&rules, target).?;
        var stale = false;
        for (rules[i].needs) |need| {
            if (stampOf(&rules, need, &sources) > rules[i].stamp) stale = true;
        }
        try out.print("  {s: <7} {s}\n", .{ target, if (stale) "rebuild" else "up to date" });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.make`)*

The stamps stand in for file modification times: higher is newer. `main.c` is
30 and `main.o` is 20, so the source has been edited since the object was
built. `util.c` is 10 against `util.o` at 20, so that one is current.

## What just happened

**The build order put the objects before the binary.** Nothing declared that
order. It falls out of visiting dependencies first and appending each target
only on the way back out. That is depth-first post-order, and it is what
"topological sort" means when you write it rather than name it.

**Only `main.o` needed rebuilding.** Its source is newer than it is. The output is newer than its source, so it was skipped. That is the whole
value proposition. On a large project almost everything is up to date, and the
comparison that establishes it is one integer against another.

**The `visiting` flag is not bookkeeping, it is the cycle check.** Each target
is marked while its dependencies are being visited and marked again when it is
done. Meeting a target that is still in the first state means the graph loops,
and the program returns `error.CircularDependency` rather than recursing until
the stack runs out. Real `make` reports exactly this, and now you know what it
noticed.

**What the program does not model** is worth naming: once `main.o` is rebuilt,
its timestamp becomes *now*, which makes `app` stale in turn. Real `make`
recomputes as it goes, so staleness propagates up the graph. The program above
reports a single snapshot, which is the honest thing for it to do given it
never runs a command.

## Check yourself

`make` is famously strict that recipe lines begin with a tab, not spaces.
Given what you have just built, is that rule doing any work?

Almost none, and its author has said as much. The tab distinguishes a recipe
line from a continuation of the rule, which a smarter parser could infer. It
survives because changing it would break every Makefile ever written, which is
the same reason a great many things in Unix are the way they are. The graph
and the timestamps are the design; the tab is an accident that could not be
undone.

## If you have written C

You have almost certainly written a Makefile without writing `make`, and the
translation is direct. A rule's prerequisites are its edges, and `$@` and `$<`
are the target and the first prerequisite of the node you are currently at.

The one thing a C implementation has to do that this program skips is get the
timestamp, with `stat`, and handle the case where the file is not there at
all. A missing target has an mtime of nothing, which has to compare as "older
than everything" so the target gets built. Representing that as 0 is exactly
what the C version does, and it is the correct simplification.

## Where to go next

That is the toolbox. Seven programs, and between them the techniques that keep
coming back. A fixed buffer and a streaming loop. A state machine. A search.
An ownership decision. A delimiter. A conversion. And a graph.

If you want the same treatment of the language itself,
[Groundwork](https://www.ziglang.in/learn/systems-from-scratch/) starts from what a byte is. If you
would rather build something larger, the [ORM](https://www.ziglang.in/learn/orm/) is one library
designed in the open, one decision per chapter.
