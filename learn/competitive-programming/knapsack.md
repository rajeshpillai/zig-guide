# Take or Skip: The 0/1 Knapsack

> Every subset, then the take-or-skip recursion, the table that stops it repeating itself, the walk back to the chosen items, and the one-row version whose loop direction decides the answer.

We have a bag that holds 10 kilograms and five items.

Each item has a weight and a value.

We want the most value that fits in the bag.

Each item goes in once or not at all.

We can't cut an item in half, and we can't take two copies of it.

The "0/1" in the name means exactly that.

The program below solves the same problem five ways and prints what each one does.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.knapsack`)*

## The problem

<SnippetSource name="23-competitive.knapsack" decl="Item" />

The input is the capacity, then a row of weights, then a row of values.

```
5 items, a bag that holds 10
  item       1   2   3   4   5
  weight     5   4   6   3   2
  value     10  40  30  50  15
```

Item 4 is light and valuable, so it is an easy pick.

The rest is harder to see by eye.

Items 2 and 3 together weigh exactly 10 and are worth 70.

Items 2, 4 and 5 weigh 9 and are worth 105.

We need a method that checks every option without actually listing every option.

## Every subset

<SnippetSource name="23-competitive.knapsack" decl="bestBySubsets" />

The certain way is to try every subset.

Each item is either in or out, so a subset fits in one bit per item.

Counting `mask` from 0 up to `2^n - 1` visits every subset exactly once.

For each mask we add up the weight and the value, and keep the best one that fits.

```
every subset of 5 items
  32 subsets tried, best is items 2 4 5, weight 9, value 105
```

Five items give 32 subsets.

Twenty items give 1,048,576.

Every extra item doubles the work, so this method is only useful as a check on small inputs.

We keep it here for that job, and every faster method below has to agree with it.

## Take or skip

<SnippetSource name="23-competitive.knapsack" decl="bestPlain" />

A better way is to decide one item at a time.

`bestPlain(items, i, cap)` answers a smaller question: what is the best value using only the first `i` items with `cap` room left?

Look at the last of those items, item `i - 1`.

There are only two choices for it.

If we skip it, the answer is the best the first `i - 1` items can do with the same room.

If we take it, we add its value and ask the first `i - 1` items what they can do with the room that is left.

We can only take it when it fits.

The answer is the larger of the two.

When `i` is 0 there are no items, so the answer is 0 whatever the room.

```
take or skip, as plain recursion
  best(5, 10) = 105
  43 calls reached 34 distinct (i, cap) states
```

The recursion agrees with the subsets.

It made 43 calls, but only 34 different questions were asked.

So 9 calls answered a question that had already been answered.

## Counting the repeats

<SnippetSource name="23-competitive.knapsack" decl="Calls" />

Nine repeats out of 43 does not look like much.

The program runs the same recursion on bigger inputs to see how the gap grows.

It repeats the five items two, three and four times and scales the bag to match.

```
  items  cap   subsets  plain calls  states  memo calls  cells
      5   10        32           43      34          41     66
     10   20      1024         1342     148         238    231
     15   30     32768        41215     332         576    496
     20   40   1048576      1286627     596        1074    861
```

Look at the `plain calls` and `states` columns.

With 20 items the recursion makes 1,286,627 calls.

There are only 596 different `(i, cap)` pairs among them.

The calls grow at about the same rate as the subsets.

The states grow much more slowly, because a state is only two small numbers.

`i` runs from 0 to `n`, and `cap` runs from 0 to the capacity.

So there can never be more states than `(n + 1) * (cap + 1)`, which is the `cells` column.

A problem where the same small set of questions comes up again and again is what dynamic programming is for.

## Remembering answers

<SnippetSource name="23-competitive.knapsack" decl="bestMemo" />

The fix is to store each answer the first time we compute it.

`Memo` is a two-dimensional array with one cell per state.

A cell is `null` until its state is solved.

The recursion itself is unchanged.

We only added a lookup at the top and a store at the bottom.

This is called memoisation.

In the table above, the `memo calls` column counts every call, including the ones that found the answer already stored.

With 20 items it made 1,074 calls instead of 1,286,627.

Each state is solved once, and a solved state makes at most two calls of its own.

So the calls can never be more than twice the states, plus one for the first call.

The arrays are fixed size, sized by `max_items` and `max_cap`, as a contest solution would do.

[Arrays](https://www.ziglang.in/learn/language-basics/arrays/) covers `@splat`, which fills them.

## The table, bottom up

<SnippetSource name="23-competitive.knapsack" decl="fillTable" />

Memoisation fills the table in whatever order the recursion asks.

We can also fill it in a fixed order, with no recursion at all.

`dp[i][c]` means the same thing as `bestPlain(items, i, c)`.

Row `i` only reads row `i - 1`.

So if we fill the rows from top to bottom, every cell a state needs is already filled.

Row 0 is no items, which is 0 everywhere.

```
dp[i][c]: best value from the first i items with room c
  first i items      0   1   2   3   4   5   6   7   8   9  10
  none               0   0   0   0   0   0   0   0   0   0   0
  + w5 v10           0   0   0   0   0  10  10  10  10  10  10
  + w4 v40           0   0   0   0  40  40  40  40  40  50  50
  + w6 v30           0   0   0   0  40  40  40  40  40  50  70
  + w3 v50           0   0   0  50  50  50  50  90  90  90  90
  + w2 v15           0   0  15  50  50  65  65  90  90 105 105
  answer dp[5][10] = 105, subsets said 105, agree -> true
```

Each row adds one item to the ones above it.

Read the row for the third item at capacity 10.

It says 70, which is items 2 and 3 filling the bag exactly.

One row later, item 4 arrives and the same cell becomes 90.

The cell now holds items 2 and 4, with 3 kilograms of room to spare.

The answer to the whole problem is the bottom-right cell.

## Which items were chosen

<SnippetSource name="23-competitive.knapsack" decl="chosenItems" />

The table holds values, not choices.

We can still recover the choices by walking back from the bottom-right cell.

Compare each cell with the one directly above it.

If they are equal, the earlier items already reach that value, so this item was not needed.

If they differ, this item must have been taken.

We then move up one row and to the left by the item's weight.

```
walking back from the bottom-right cell
  item 5 (w2 v15)  dp[5][10] = 105, above  90  -> take, room 10 -> 8
  item 4 (w3 v50)  dp[4][ 8] =  90, above  40  -> take, room 8 -> 5
  item 3 (w6 v30)  dp[3][ 5] =  40, above  40  -> skip
  item 2 (w4 v40)  dp[2][ 5] =  40, above  10  -> take, room 5 -> 1
  item 1 (w5 v10)  dp[1][ 1] =   0, above   0  -> skip
  chosen: items 2 4 5, weight 9, value 105
```

The walk lands on items 2, 4 and 5, the same set the subset search found.

Two different sets can tie for the best value.

This walk skips an item whenever skipping keeps the same value, so a tie goes to the set without the later item.

A judge that wants one particular set will say how to break ties.

## One row instead of a table

<SnippetSource name="23-competitive.knapsack" decl="rollDown" />

Each row only reads the row above it.

So we don't need to keep the whole table.

One row is enough, if we overwrite it carefully.

`best[c]` starts as the old row's value.

For each item we update it in place, running the capacity from high to low.

```
one row, capacity loop running downward
  after item         0   1   2   3   4   5   6   7   8   9  10
  + w5 v10           0   0   0   0   0  10  10  10  10  10  10
  + w4 v40           0   0   0   0  40  40  40  40  40  50  50
  + w6 v30           0   0   0   0  40  40  40  40  40  50  70
  + w3 v50           0   0   0  50  50  50  50  90  90  90  90
  + w2 v15           0   0  15  50  50  65  65  90  90 105 105
  every row matches the table -> true, answer 105
```

After each item, the single row equals the matching row of the full table.

Memory drops from `(n + 1) * (W + 1)` cells to `W + 1`.

The cost is the walk back.

With only one row left, there is nothing to compare against, so this version gives the best value but not the items.

If a problem asks for the items, keep the table.

## The loop must run downward

<SnippetSource name="23-competitive.knapsack" decl="rollUp" />

The downward direction is not a style choice.

When we compute `best[c]`, we read `best[c - w]`, which is a cell to its left.

Running downward, the cells to the left have not been touched yet for this item.

They still hold the previous row, which is what the formula needs.

Running upward, the cells to the left were updated a moment ago.

They may already include this item.

Adding the item's value again takes the item a second time.

```
one row, capacity loop running upward
  after item         0   1   2   3   4   5   6   7   8   9  10
  + w5 v10           0   0   0   0   0  10  10  10  10  10  20
  + w4 v40           0   0   0   0  40  40  40  40  80  80  80
  + w6 v30           0   0   0   0  40  40  40  40  80  80  80
  + w3 v50           0   0   0  50  50  50 100 100 100 150 150
  + w2 v15           0   0  15  50  50  65 100 100 115 150 150
  answer 150, but the 0/1 answer is 105
```

The first row already shows it.

Item 1 weighs 5 and is worth 10, and the cell at capacity 10 says 20.

Two copies of item 1 make that 20.

The row for item 4 says 100 at capacity 6 and 150 at capacity 9, which are two and three copies of it.

The upward loop still compiles, runs and returns a reasonable-looking number.

The number answers a different problem.

<SnippetSource name="23-competitive.knapsack" decl="bestUnbounded" />

That problem is the unbounded knapsack, where each item can be taken any number of times.

`bestUnbounded` solves it with the loops the other way round, capacity outside and items inside.

```
  the unbounded knapsack, any item any number of times, gives 150 -> agree true
```

So when a problem does allow repeats, the upward loop is the correct one.

Read the statement for "each item at most once" or "unlimited supply" before choosing the direction.

## What it costs

The table has `(n + 1) * (W + 1)` cells, where `W` is the capacity.

Each cell takes a constant amount of work.

So the whole thing is O(n * W) time.

The full table is O(n * W) memory, and the single row is O(W).

Compare that with the 2^n subsets.

For 100 items and a capacity of 10,000, the table has about a million cells.

The subsets would number about 10^30.

There is a problem with `W`.

`W` is a number from the input, not the length of anything.

Writing `W` takes only a handful of digits, but the table needs `W + 1` columns.

A capacity of 1,000,000,000 is ten characters in the input and a billion columns in the row.

So the running time is called pseudo-polynomial.

It is polynomial in the value of `W`, not in the size of the input.

So check the bounds before using this table.

If `W` is up to about 10^5 or 10^6, the table fits.

If `W` is up to 10^9 and the values are small, the usual approach is to swap the roles: index the table by total value and store the least weight that reaches it.

## The width of a total

The weights and values are read as `u32`.

Every total in the program is `u64`.

A total is a sum of up to `n` values, and a sum can outgrow the type of the numbers it adds.

```
the width of a total
  u32 holds up to 4294967295
  100 items of value 1000000000 add up to 100000000000
```

A hundred values of 10^9 each fit in `u32` one at a time.

Their sum does not.

In a Debug or ReleaseSafe build that addition panics.

In ReleaseFast it is illegal behaviour, and the program may carry on with a wrong total.

[Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) covers what Zig does when an addition overflows.

For a contest, take the largest possible value, multiply by the number of items, and pick a type that holds the product.
