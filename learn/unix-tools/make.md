# make

> A dependency graph, a topological order, and a comparison of timestamps.

People know `make` as a language with strange rules about tabs. Remove the
syntax, and two small ideas remain. This chapter builds both ideas, so that
the tool is easier to understand.

The first idea: **the targets make a graph.** `app` needs `main.o` and
`util.o`, and each object needs its `.c` file. To build in the correct order,
visit a node only after all of the nodes that it depends on. That is a
topological sort.

The second idea: **a timestamp decides if work occurs.** A target is stale if
one of its dependencies is newer than the target. Because of this one
comparison, `make` is faster than a shell script that builds everything again.

## The program

```zig
const std = @import("std");

const Rule = struct {
    target: []const u8,
    needs: []const []const u8,
    /// In place of the mtime of the file. Higher is newer. 0 means absent.
    stamp: u64,
};

/// Visit the dependencies before the target that depends on them, and do not
/// loop. This is all of the order logic of make. State 1 ("visit in progress")
/// changes an infinite recursion into an error that you can report.
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

    // `@splat`, not the `**` repeat operator. The language removed `**`.
    var state: [rules.len]u8 = @splat(0);
    var scheduled: std.ArrayList([]const u8) = .empty;
    defer scheduled.deinit(allocator);
    try order(&rules, "app", &state, &scheduled, allocator);

    try out.writeAll("build order:\n");
    for (scheduled.items) |target| try out.print("  {s}\n", .{target});

    // A target is stale when one of its dependencies is newer than the target.
    // Because of this one comparison, make is faster than a shell script.
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

The stamps are in place of file modification times, and a higher stamp is
newer. `main.c` is 30 and `main.o` is 20. Thus someone edited the source after
the last build of the object. `util.c` is 10 and `util.o` is 20, so `util.o`
is current.

## What just happened

**The build order put the objects before the binary.** No line declared that
order. The order is the result of two rules: visit the dependencies first, and
append each target only on the return. This is depth-first post-order, and it
is how you write a topological sort in code.

**Only `main.o` needed a new build.** Its source is newer than `main.o`.
`util.o` is newer than its source, so the program skipped `util.o`. Here,
`make` saves time. On a large project, almost all targets are current, and
the check costs one integer comparison for each target.

**The `state` array is the cycle check.** The program marks each target 1
while it visits the dependencies of that target. It marks the target 2 when the
visit is complete. If the program finds a target that is still 1, the graph has
a loop.

In that case, the program returns `error.CircularDependency`. It does not
recurse until the stack overflows. Real `make` also finds the loop. It prints
`Circular b <- a dependency dropped`, removes the edge, and continues.

**The program does not model one thing.** When `make` builds `main.o` again,
the timestamp of `main.o` becomes *now*. Then `app` is stale too. Real `make`
calculates again after each step, so the stale state moves up the graph. The
program above never runs a command. Thus it reports only one snapshot of the
stale targets.

## Check yourself

`make` is famously strict about a rule: a recipe line starts with a tab, not
spaces. You built the tool above. Does that rule do any work?

The rule does almost no work, and the author of `make` said this too. The tab shows the
difference between a recipe line and a continuation of the rule. A better
parser can find that difference without the tab.

The rule stays because a change can break each Makefile that exists. Many
things in Unix stay the same for this reason. The graph and the timestamps are
the design. The tab is an early decision that nobody could change later.

## If you know C

Almost certainly, you wrote a Makefile but never wrote `make`. The
translation is direct. The prerequisites of a rule are its edges. `$@` and
`$<` are the target and the first prerequisite of the node that you are at.

A C implementation must do one thing that this program skips. It must get the
timestamp with `stat`, and it must handle a file that does not exist. A target
that does not exist has no mtime. That target must compare as "older than
everything", so that `make` builds it. The C version uses 0 for this case, and
that is the correct simplification.

## Where to go next

This is the last of the seven programs. Together, the programs use these
ideas:

- A fixed buffer with a streaming loop.
- A state machine.
- A search.
- An ownership decision.
- A delimiter.
- A conversion.
- A graph.

[Groundwork](https://www.ziglang.in/learn/systems-from-scratch/) gives the same treatment to the
language itself, and it starts from what a byte is. For a larger project, see
the [ORM](https://www.ziglang.in/learn/orm/). It is one library with an open design, with one
decision in each chapter.
