//! title: make
//! A dependency graph, a topological order, and a comparison of timestamps.

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
