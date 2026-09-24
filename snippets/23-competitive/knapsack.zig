//! title: Take or Skip: The 0/1 Knapsack
//! Five items and a bag that holds ten. The program tries every subset, then
//! the take-or-skip recursion with a count of how often it repeats itself,
//! then the memoised version, the bottom-up table and the walk back through it,
//! and last the one-row version run in both directions, so the wrong direction
//! prints its wrong answer next to the right one.

const std = @import("std");

/// The problem: the bag's capacity, then each item's weight, then its value.
const input =
    \\10
    \\5 4 6 3 2
    \\10 40 30 50 15
;

/// Contest-sized bounds. The largest run below repeats the five items four
/// times, so 20 items and a capacity of 40 cover every table in this file.
const max_items = 20;
const max_cap = 40;

/// Read one line of whitespace-separated values into `out`.
fn readRow(reader: *std.Io.Reader, out: []u32) ![]u32 {
    const line = (try reader.takeDelimiter('\n')) orelse return error.MissingRow;
    var count: usize = 0;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        if (count == out.len) return error.RowTooLong;
        out[count] = try std.fmt.parseInt(u32, field, 10);
        count += 1;
    }
    return out[0..count];
}

/// Weights and values are read as `u32`. Every total is a `u64`, because a
/// total is a sum of up to `max_items` values and a sum can outgrow the type
/// of the things it adds.
const Item = struct {
    weight: u32,
    value: u32,
};

/// Try every subset of the items, one bit per item.
///
/// Bit `i` of `mask` set means item `i` is in the bag. There are `2^n` masks,
/// so this is the answer every faster method below has to agree with, and the
/// cost none of them can afford once `n` passes about 25.
fn bestBySubsets(items: []const Item, cap: u32, tried: *u64) struct { value: u64, mask: u32 } {
    var best: u64 = 0;
    var best_mask: u32 = 0;
    const masks = @as(u32, 1) << @intCast(items.len);
    var mask: u32 = 0;
    while (mask < masks) : (mask += 1) {
        tried.* += 1;
        var weight: u64 = 0;
        var value: u64 = 0;
        for (items, 0..) |item, i| {
            if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
                weight += item.weight;
                value += item.value;
            }
        }
        if (weight <= cap and value > best) {
            best = value;
            best_mask = mask;
        }
    }
    return .{ .value = best, .mask = best_mask };
}

/// Counts for the recursion: every call, and which `(i, cap)` pairs it reached.
const Calls = struct {
    calls: u64 = 0,
    seen: [max_items + 1][max_cap + 1]bool = @splat(@splat(false)),

    fn states(self: *const Calls) u64 {
        var count: u64 = 0;
        for (self.seen) |row| {
            for (row) |hit| count += @intFromBool(hit);
        }
        return count;
    }
};

/// The best value using only the first `i` items with `cap` room left.
///
/// Look at item `i - 1` and make the one choice there is. Skip it, and the
/// answer is whatever the first `i - 1` items do with the same room. Take it,
/// if it fits, and the answer is its value plus what the first `i - 1` items
/// do with the room that is left. The larger of the two wins.
fn bestPlain(items: []const Item, i: usize, cap: u32, stats: *Calls) u64 {
    stats.calls += 1;
    stats.seen[i][cap] = true;
    if (i == 0) return 0;
    const item = items[i - 1];
    const skip = bestPlain(items, i - 1, cap, stats);
    if (item.weight > cap) return skip;
    const take = item.value + bestPlain(items, i - 1, cap - item.weight, stats);
    return @max(skip, take);
}

/// One cell per `(i, cap)` state, null until that state has been solved.
const Memo = [max_items + 1][max_cap + 1]?u64;

/// `bestPlain` with a table in front of it.
///
/// The recursion is unchanged. The only new lines are the lookup at the top
/// and the store at the bottom, so each state is solved once and every later
/// call for it is a read.
fn bestMemo(items: []const Item, i: usize, cap: u32, memo: *Memo, calls: *u64) u64 {
    calls.* += 1;
    if (memo[i][cap]) |known| return known;
    const result = if (i == 0) 0 else blk: {
        const item = items[i - 1];
        const skip = bestMemo(items, i - 1, cap, memo, calls);
        if (item.weight > cap) break :blk skip;
        const take = item.value + bestMemo(items, i - 1, cap - item.weight, memo, calls);
        break :blk @max(skip, take);
    };
    memo[i][cap] = result;
    return result;
}

const Table = [max_items + 1][max_cap + 1]u64;

/// The same states, filled in order instead of on demand.
///
/// Row `i` depends only on row `i - 1`, so filling rows top to bottom means
/// both cells a state needs are already there. Row 0 is no items at all, which
/// is zero at every capacity.
fn fillTable(items: []const Item, cap: u32, dp: *Table) void {
    for (0..cap + 1) |c| dp[0][c] = 0;
    for (items, 1..) |item, i| {
        for (0..cap + 1) |c| {
            dp[i][c] = dp[i - 1][c];
            if (item.weight <= c) {
                dp[i][c] = @max(dp[i][c], item.value + dp[i - 1][c - item.weight]);
            }
        }
    }
}

/// Recover the chosen items by walking back up the table.
///
/// If `dp[i][c]` equals the cell above it, the first `i - 1` items already
/// reach that value at this capacity, so item `i` can be skipped. Otherwise
/// item `i` had to be taken, and the walk continues from the room it left.
/// Each decision is printed as it is made, and the chosen items come back as
/// a mask in the same bit layout `bestBySubsets` uses.
fn chosenItems(items: []const Item, cap: u32, dp: *const Table, out: *std.Io.Writer) !u32 {
    var mask: u32 = 0;
    var c = cap;
    var i = items.len;
    while (i > 0) : (i -= 1) {
        const item = items[i - 1];
        const here = dp[i][c];
        const above = dp[i - 1][c];
        try out.print("  item {d} (w{d} v{d:<2})  dp[{d}][{d:>2}] = {d:>3}, above {d:>3}  ", .{
            i, item.weight, item.value, i, c, here, above,
        });
        if (here == above) {
            try out.writeAll("-> skip\n");
        } else {
            try out.print("-> take, room {d} -> {d}\n", .{ c, c - item.weight });
            mask |= @as(u32, 1) << @intCast(i - 1);
            c -= item.weight;
        }
    }
    return mask;
}

/// One item folded into the single-row table, capacity running downward.
///
/// `best[c - w]` is read before anything at a lower capacity is written, so it
/// still holds the previous item's row. Each item is counted at most once.
fn rollDown(best: []u64, item: Item) void {
    var c = best.len;
    while (c > item.weight) {
        c -= 1;
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}

/// The same loop with the capacity running upward. This one is wrong for 0/1.
///
/// By the time `best[c]` is computed, `best[c - w]` may already include this
/// item, so adding the item again takes it twice. The loop solves a different
/// problem: each item may be taken any number of times.
fn rollUp(best: []u64, item: Item) void {
    if (item.weight >= best.len) return;
    for (item.weight..best.len) |c| {
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}

/// The unbounded knapsack, written independently of `rollUp` to check it.
///
/// Capacity on the outside and items on the inside, so nothing about the
/// order of the loops is shared with the function it is checking.
fn bestUnbounded(items: []const Item, cap: u32) u64 {
    var best: [max_cap + 1]u64 = @splat(0);
    for (1..cap + 1) |c| {
        for (items) |item| {
            if (item.weight <= c) best[c] = @max(best[c], item.value + best[c - item.weight]);
        }
    }
    return best[cap];
}

fn writeCaps(out: *std.Io.Writer, label: []const u8, cap: u32) !void {
    try out.print("  {s: <16}", .{label});
    for (0..cap + 1) |c| try out.print("{d:>4}", .{c});
    try out.writeByte('\n');
}

fn writeRow(out: *std.Io.Writer, label: []const u8, row: []const u64) !void {
    try out.print("  {s: <16}", .{label});
    for (row) |v| try out.print("{d:>4}", .{v});
    try out.writeByte('\n');
}

fn writeMask(out: *std.Io.Writer, items: []const Item, mask: u32) !void {
    var weight: u64 = 0;
    var value: u64 = 0;
    try out.writeAll("items");
    for (items, 0..) |item, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) {
            try out.print(" {d}", .{i + 1});
            weight += item.weight;
            value += item.value;
        }
    }
    try out.print(", weight {d}, value {d}", .{ weight, value });
}

fn itemLabel(buf: []u8, item: Item) ![]u8 {
    return std.mem.print(buf, "+ w{d} v{d}", .{ item.weight, item.value });
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var cap_storage: [1]u32 = undefined;
    var weight_storage: [max_items]u32 = undefined;
    var value_storage: [max_items]u32 = undefined;
    const cap = (try readRow(&reader, &cap_storage))[0];
    const weights = try readRow(&reader, &weight_storage);
    const values = try readRow(&reader, &value_storage);
    if (weights.len != values.len) return error.RowLengthsDiffer;

    var item_storage: [max_items]Item = undefined;
    for (weights, values, 0..) |w, v, i| item_storage[i] = .{ .weight = w, .value = v };
    const items = item_storage[0..weights.len];

    try out.print("{d} items, a bag that holds {d}\n", .{ items.len, cap });
    try out.writeAll("  item    ");
    for (1..items.len + 1) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  weight  ");
    for (items) |item| try out.print("{d:>4}", .{item.weight});
    try out.writeAll("\n  value   ");
    for (items) |item| try out.print("{d:>4}", .{item.value});
    try out.writeAll("\n\n");

    // Every subset, the slow and certain way.
    var tried: u64 = 0;
    const brute = bestBySubsets(items, cap, &tried);
    try out.print("every subset of {d} items\n", .{items.len});
    try out.print("  {d} subsets tried, best is ", .{tried});
    try writeMask(out, items, brute.mask);
    try out.writeAll("\n\n");

    // The recursion, counting calls against the states it actually visits.
    var plain: Calls = .{};
    const recursive = bestPlain(items, items.len, cap, &plain);
    try out.writeAll("take or skip, as plain recursion\n");
    try out.print("  best({d}, {d}) = {d}\n", .{ items.len, cap, recursive });
    try out.print("  {d} calls reached {d} distinct (i, cap) states\n\n", .{ plain.calls, plain.states() });

    // The same recursion on bigger copies of the same items.
    try out.writeAll("the same items repeated, with the bag scaled to match\n");
    try out.writeAll("  items  cap   subsets  plain calls  states  memo calls  cells\n");
    var k: u32 = 1;
    while (k * items.len <= max_items and k * cap <= max_cap) : (k += 1) {
        var big_storage: [max_items]Item = undefined;
        const n = k * items.len;
        for (0..n) |i| big_storage[i] = items[i % items.len];
        const big = big_storage[0..n];
        const big_cap = k * cap;
        var stats: Calls = .{};
        const a = bestPlain(big, n, big_cap, &stats);
        var memo: Memo = @splat(@splat(null));
        var memo_calls: u64 = 0;
        const b = bestMemo(big, n, big_cap, &memo, &memo_calls);
        if (a != b) return error.MemoDisagrees;
        try out.print("  {d:>5} {d:>4} {d:>9} {d:>12} {d:>7} {d:>11} {d:>6}\n", .{
            n,
            big_cap,
            @as(u64, 1) << @intCast(n),
            stats.calls,
            stats.states(),
            memo_calls,
            (n + 1) * (big_cap + 1),
        });
    }
    try out.writeByte('\n');

    // Bottom-up: the whole table, printed.
    var dp: Table = undefined;
    fillTable(items, cap, &dp);
    try out.writeAll("dp[i][c]: best value from the first i items with room c\n");
    try writeCaps(out, "first i items", cap);
    try writeRow(out, "none", dp[0][0 .. cap + 1]);
    for (items, 1..) |item, i| {
        var label: [16]u8 = undefined;
        try writeRow(out, try itemLabel(&label, item), dp[i][0 .. cap + 1]);
    }
    try out.print("  answer dp[{d}][{d}] = {d}, subsets said {d}, agree -> {}\n\n", .{
        items.len, cap, dp[items.len][cap], brute.value, dp[items.len][cap] == brute.value,
    });

    try out.writeAll("walking back from the bottom-right cell\n");
    const mask = try chosenItems(items, cap, &dp, out);
    try out.writeAll("  chosen: ");
    try writeMask(out, items, mask);
    try out.writeAll("\n\n");

    // One row instead of a table, and the direction the capacity loop runs.
    var down: [max_cap + 1]u64 = @splat(0);
    var up: [max_cap + 1]u64 = @splat(0);
    const down_row = down[0 .. cap + 1];
    const up_row = up[0 .. cap + 1];
    try out.writeAll("one row, capacity loop running downward\n");
    try writeCaps(out, "after item", cap);
    var rows_match = true;
    for (items, 1..) |item, i| {
        rollDown(down_row, item);
        if (!std.mem.eql(u64, down_row, dp[i][0 .. cap + 1])) rows_match = false;
        var label: [16]u8 = undefined;
        try writeRow(out, try itemLabel(&label, item), down_row);
    }
    try out.print("  every row matches the table -> {}, answer {d}\n\n", .{ rows_match, down_row[cap] });

    try out.writeAll("one row, capacity loop running upward\n");
    try writeCaps(out, "after item", cap);
    for (items) |item| {
        rollUp(up_row, item);
        var label: [16]u8 = undefined;
        try writeRow(out, try itemLabel(&label, item), up_row);
    }
    const unbounded = bestUnbounded(items, cap);
    try out.print("  answer {d}, but the 0/1 answer is {d}\n", .{ up_row[cap], down_row[cap] });
    try out.print("  the unbounded knapsack, any item any number of times, gives {d} -> agree {}\n\n", .{
        unbounded, unbounded == up_row[cap],
    });

    // Why the totals are u64.
    const many: u64 = 100;
    const each: u64 = 1_000_000_000;
    try out.writeAll("the width of a total\n");
    try out.print("  u32 holds up to {d}\n", .{std.math.maxInt(u32)});
    try out.print("  {d} items of value {d} add up to {d}\n", .{ many, each, many * each });

    try out.flush();
}
