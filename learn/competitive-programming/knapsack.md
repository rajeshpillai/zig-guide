# Take or Skip: The 0/1 Knapsack

> All subsets, the take-or-skip recursion, the table that stops repeats, the walk back to the items, and the one-row version with its loop direction.

A bag holds 10 kilograms, and there are five items. Each item has a weight and a value. The problem is to get the most value that fits in the bag.

Each item goes into the bag one time or not at all. You cannot cut an item in half, and you cannot take two copies of an item. The "0/1" in the name means exactly this rule.

The program below solves the same problem in five ways. It prints the work that each method does.

```zig
const std = @import("std");

/// The problem: the capacity of the bag, then the weight of each item, then
/// the value of each item.
const input =
    \\10
    \\5 4 6 3 2
    \\10 40 30 50 15
;

/// Limits of the size that a contest uses. The largest run below repeats the
/// five items four times. Thus 20 items and a capacity of 40 are sufficient
/// for each table in this file.
const max_items = 20;
const max_cap = 40;

/// Read one line of values into `out`. Whitespace separates the values.
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

/// The program reads weights and values as `u32`. Each total is a `u64`,
/// because a total is a sum of a maximum of `max_items` values. A sum can
/// become too large for the type of the numbers that it adds.
const Item = struct {
    weight: u32,
    value: u32,
};

/// Try all subsets of the items, with one bit for each item.
///
/// If bit `i` of `mask` is 1, item `i` is in the bag. There are `2^n` masks.
/// Thus each faster method below must give the same answer as this function.
/// But when `n` is more than approximately 25, no method can use this
/// function, because the cost is too high.
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

/// Counts for the recursion: all of the calls, and the `(i, cap)` pairs that
/// the calls got to.
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

/// The best value from only the first `i` items, when `cap` is the space
/// that is left.
///
/// Look at item `i - 1` and make the one choice for it. If you skip the item,
/// the answer is the best value from the first `i - 1` items with the same
/// space. You can take the item only if it fits. Then the answer is its value
/// plus the best value from the first `i - 1` items with the space that is
/// left. The answer is the larger of the two values.
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

/// One cell for each `(i, cap)` state. A cell is null until the function
/// solves its state.
const Memo = [max_items + 1][max_cap + 1]?u64;

/// `bestPlain` with a table before it.
///
/// The recursion does not change. The only new lines are the lookup at the
/// start and the store at the end. Thus the function solves each state one
/// time, and each later call for that state only reads the table.
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

/// The same states, but the function fills them in order. It does not wait
/// for a request.
///
/// Row `i` uses only row `i - 1`. Thus, if the function fills the rows from
/// the top to the bottom, the two cells that a state needs already have a
/// value. Row 0 has no items, thus it is zero at each capacity.
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

/// Find the selected items again. Start at the bottom of the table and move up.
///
/// If `dp[i][c]` is equal to the cell above it, the first `i - 1` items
/// already give that value at this capacity. Thus the function can skip item
/// `i`. If not, the function had to take item `i`, and the walk continues from
/// the space that item `i` left. The function prints each decision when it
/// makes the decision. It returns the selected items as a mask, with the same
/// bit layout as `bestBySubsets`.
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

/// Add one item to the single-row table. The capacity goes downward.
///
/// The function reads `best[c - w]` before it writes a cell at a lower
/// capacity. Thus `best[c - w]` still holds the row of the previous item. The
/// function counts each item a maximum of one time.
fn rollDown(best: []u64, item: Item) void {
    var c = best.len;
    while (c > item.weight) {
        c -= 1;
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}

/// The same loop, but the capacity goes upward. This loop is wrong for 0/1.
///
/// When the function calculates `best[c]`, `best[c - w]` can already include
/// this item. Thus the function adds the item again and takes it two times.
/// The loop solves a different problem: you can take each item any number of
/// times.
fn rollUp(best: []u64, item: Item) void {
    if (item.weight >= best.len) return;
    for (item.weight..best.len) |c| {
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}

/// The unbounded knapsack. This function does not use code from `rollUp`,
/// thus it can check `rollUp`.
///
/// The capacity loop is outside and the item loop is inside. Thus the order
/// of the loops is different from the order in the function that it checks.
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

    // All subsets, the slow and certain method.
    var tried: u64 = 0;
    const brute = bestBySubsets(items, cap, &tried);
    try out.print("every subset of {d} items\n", .{items.len});
    try out.print("  {d} subsets tried, best is ", .{tried});
    try writeMask(out, items, brute.mask);
    try out.writeAll("\n\n");

    // The recursion. Compare the count of calls with the count of states
    // that the calls get to.
    var plain: Calls = .{};
    const recursive = bestPlain(items, items.len, cap, &plain);
    try out.writeAll("take or skip, as plain recursion\n");
    try out.print("  best({d}, {d}) = {d}\n", .{ items.len, cap, recursive });
    try out.print("  {d} calls reached {d} distinct (i, cap) states\n\n", .{ plain.calls, plain.states() });

    // The same recursion on larger copies of the same items.
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

    // Bottom-up: print the full table.
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

    // One row instead of a table, and the direction of the capacity loop.
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

    // The reason that the totals are u64.
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

```zig
/// The program reads weights and values as `u32`. Each total is a `u64`,
/// because a total is a sum of a maximum of `max_items` values. A sum can
/// become too large for the type of the numbers that it adds.
const Item = struct {
    weight: u32,
    value: u32,
};
```

*Quoted from the source: `Item` from `snippets/23-competitive/knapsack.zig`.*

The input is the capacity, then a row of weights, then a row of values.

```
5 items, a bag that holds 10
  item       1   2   3   4   5
  weight     5   4   6   3   2
  value     10  40  30  50  15
```

Item 4 is light and has a high value. Thus item 4 is an easy choice.

For the other items, the best choice is not easy to see:

- Items 2 and 3 together weigh exactly 10, and their value is 70.
- Items 2, 4 and 5 weigh 9, and their value is 105.

You need a method that checks all of the options, but does not make a list of each option.

## Try all subsets

```zig
/// Try all subsets of the items, with one bit for each item.
///
/// If bit `i` of `mask` is 1, item `i` is in the bag. There are `2^n` masks.
/// Thus each faster method below must give the same answer as this function.
/// But when `n` is more than approximately 25, no method can use this
/// function, because the cost is too high.
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
```

*Quoted from the source: `bestBySubsets` from `snippets/23-competitive/knapsack.zig`.*

The certain method is to try all of the subsets. Each item is in the subset or not in it. Thus one bit for each item is sufficient to keep a subset.

When `mask` counts from 0 to `2^n - 1`, it gets to each subset exactly one time. For each mask, the function adds the weights and the values. It keeps the best subset that fits.

```
every subset of 5 items
  32 subsets tried, best is items 2 4 5, weight 9, value 105
```

Five items give 32 subsets. Twenty items give 1,048,576. Each new item doubles the work. Thus this method is useful only as a check on small inputs.

The program keeps this method for that check. Each faster method below must give the same answer.

## Take or skip

```zig
/// The best value from only the first `i` items, when `cap` is the space
/// that is left.
///
/// Look at item `i - 1` and make the one choice for it. If you skip the item,
/// the answer is the best value from the first `i - 1` items with the same
/// space. You can take the item only if it fits. Then the answer is its value
/// plus the best value from the first `i - 1` items with the space that is
/// left. The answer is the larger of the two values.
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
```

*Quoted from the source: `bestPlain` from `snippets/23-competitive/knapsack.zig`.*

A better method is to decide about one item at a time.

`bestPlain(items, i, cap)` answers a smaller question: what is the best value from only the first `i` items, when `cap` is the space that is left?

Look at the last of these items, item `i - 1`. For this item, there are only two choices:

- Skip the item. Then the answer is the best value from the first `i - 1` items with the same space.
- Take the item. Then add its value, and get the best value from the first `i - 1` items with the space that is left. You can take the item only when it fits.

The answer is the larger of the two values. When `i` is 0, there are no items. Thus the answer is 0 for all values of the space.

```
take or skip, as plain recursion
  best(5, 10) = 105
  43 calls reached 34 distinct (i, cap) states
```

The recursion gives the same answer as the subsets. It made 43 calls, but it asked only 34 different questions. Thus 9 calls asked a question that had an answer already.

## Count the repeats

```zig
/// Counts for the recursion: all of the calls, and the `(i, cap)` pairs that
/// the calls got to.
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
```

*Quoted from the source: `Calls` from `snippets/23-competitive/knapsack.zig`.*

Nine repeats in 43 calls do not look like many. The program runs the same recursion on larger inputs to show how the difference grows. It repeats the five items two, three and four times, and it makes the bag larger by the same factor.

```
  items  cap   subsets  plain calls  states  memo calls  cells
      5   10        32           43      34          41     66
     10   20      1024         1342     148         238    231
     15   30     32768        41215     332         576    496
     20   40   1048576      1286627     596        1074    861
```

Look at the `plain calls` and `states` columns. With 20 items, the recursion makes 1,286,627 calls. But these calls have only 596 different `(i, cap)` pairs.

The calls grow at approximately the same rate as the subsets. The states grow much more slowly, because a state is only two small numbers:

- `i` goes from 0 to `n`.
- `cap` goes from 0 to the capacity.

Thus the number of states is never more than `(n + 1) * (cap + 1)`, which is the `cells` column.

Dynamic programming is for this type of problem, where the same small set of questions occurs again and again.

## Keep the answers

```zig
/// `bestPlain` with a table before it.
///
/// The recursion does not change. The only new lines are the lookup at the
/// start and the store at the end. Thus the function solves each state one
/// time, and each later call for that state only reads the table.
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
```

*Quoted from the source: `bestMemo` from `snippets/23-competitive/knapsack.zig`.*

The solution is to keep each answer the first time that the function calculates it. `Memo` is a two-dimensional array with one cell for each state. A cell is `null` until the function solves its state.

The recursion does not change. The function has only one new lookup at the start and one new store at the end. The name of this method is memoisation.

In the table above, the `memo calls` column counts all of the calls. This count includes the calls that found a stored answer. With 20 items, the function made 1,074 calls instead of 1,286,627.

The function solves each state one time, and a solved state makes a maximum of two calls. Thus the number of calls is never more than two times the number of states, plus one for the first call.

The arrays have a fixed size, from `max_items` and `max_cap`, as in a contest solution. [Arrays](https://www.ziglang.in/learn/language-basics/arrays/) tells about `@splat`, which fills the arrays.

## Fill the table from the bottom up

```zig
/// The same states, but the function fills them in order. It does not wait
/// for a request.
///
/// Row `i` uses only row `i - 1`. Thus, if the function fills the rows from
/// the top to the bottom, the two cells that a state needs already have a
/// value. Row 0 has no items, thus it is zero at each capacity.
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
```

*Quoted from the source: `fillTable` from `snippets/23-competitive/knapsack.zig`.*

Memoisation fills the table in the order that the recursion asks for. You can also fill the table in a fixed order, with no recursion.

`dp[i][c]` has the same meaning as `bestPlain(items, i, c)`. Row `i` reads only row `i - 1`. Thus, if you fill the rows from the top to the bottom, each cell that a state needs is already filled. Row 0 has no items, thus it is 0 in each cell.

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

Each row adds one item to the items in the rows above it.

Read the row for the third item at capacity 10. The value is 70: items 2 and 3 fill the bag exactly. The next row adds item 4, and the same cell becomes 90. Now the cell holds items 2 and 4, and 3 kilograms of space are empty.

The answer to the full problem is the cell at the bottom right.

## Find the selected items

```zig
/// Find the selected items again. Start at the bottom of the table and move up.
///
/// If `dp[i][c]` is equal to the cell above it, the first `i - 1` items
/// already give that value at this capacity. Thus the function can skip item
/// `i`. If not, the function had to take item `i`, and the walk continues from
/// the space that item `i` left. The function prints each decision when it
/// makes the decision. It returns the selected items as a mask, with the same
/// bit layout as `bestBySubsets`.
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
```

*Quoted from the source: `chosenItems` from `snippets/23-competitive/knapsack.zig`.*

The table holds values, not choices. But you can find the choices again. Start at the cell at the bottom right and move back through the table.

Compare each cell with the cell immediately above it:

- If the two cells are equal, the earlier items already give that value. Thus the function did not need this item.
- If the two cells are different, the function took this item. Then move up one row, and move left by the weight of the item.

```
walking back from the bottom-right cell
  item 5 (w2 v15)  dp[5][10] = 105, above  90  -> take, room 10 -> 8
  item 4 (w3 v50)  dp[4][ 8] =  90, above  40  -> take, room 8 -> 5
  item 3 (w6 v30)  dp[3][ 5] =  40, above  40  -> skip
  item 2 (w4 v40)  dp[2][ 5] =  40, above  10  -> take, room 5 -> 1
  item 1 (w5 v10)  dp[1][ 1] =   0, above   0  -> skip
  chosen: items 2 4 5, weight 9, value 105
```

The walk gives items 2, 4 and 5. The subset search found the same set.

The figure fills the table one row at a time, then walks back from the last cell. At the answer, it stops and asks you to predict the first decision.

*Figure: A table of 6 rows and 11 columns. Each row adds one item. Then a path from the bottom-right cell marks which items are in the bag. The table and the walk back from the program above. A filled cell is an item in the bag, and an outlined cell is a skip. The walk stops at the answer and asks you to predict the first decision.*

Two different sets can have the same best value. The walk skips an item when the skip keeps the same value. Thus, when two sets are equal, the walk selects the set without the later item. If a judge wants one specific set, the problem tells you how to select between equal sets.

## Use one row instead of a table

```zig
/// Add one item to the single-row table. The capacity goes downward.
///
/// The function reads `best[c - w]` before it writes a cell at a lower
/// capacity. Thus `best[c - w]` still holds the row of the previous item. The
/// function counts each item a maximum of one time.
fn rollDown(best: []u64, item: Item) void {
    var c = best.len;
    while (c > item.weight) {
        c -= 1;
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}
```

*Quoted from the source: `rollDown` from `snippets/23-competitive/knapsack.zig`.*

Each row reads only the row above it. Thus you do not need to keep the full table. One row is sufficient, if you write over it carefully.

At the start, `best[c]` holds the value from the old row. For each item, the function updates `best[c]` in place, and the capacity goes from high to low.

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

After each item, the single row is equal to the same row of the full table. The memory decreases from `(n + 1) * (W + 1)` cells to `W + 1`.

The cost is the walk back. With only one row, there is no row above to compare with. Thus this version gives the best value but not the items. If a problem asks for the items, keep the table.

## Run the loop downward

```zig
/// The same loop, but the capacity goes upward. This loop is wrong for 0/1.
///
/// When the function calculates `best[c]`, `best[c - w]` can already include
/// this item. Thus the function adds the item again and takes it two times.
/// The loop solves a different problem: you can take each item any number of
/// times.
fn rollUp(best: []u64, item: Item) void {
    if (item.weight >= best.len) return;
    for (item.weight..best.len) |c| {
        best[c] = @max(best[c], item.value + best[c - item.weight]);
    }
}
```

*Quoted from the source: `rollUp` from `snippets/23-competitive/knapsack.zig`.*

The downward direction is necessary. When the function calculates `best[c]`, it reads `best[c - w]`, which is a cell to the left.

The two directions give different results:

- Downward: for this item, the function did not change the cells to the left yet. These cells still hold the previous row, and the formula needs the previous row.
- Upward: the function changed the cells to the left a short time before. These cells can already include this item. Then the function adds the value of the item again, and it takes the item a second time.

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

The first row already shows the problem. Item 1 weighs 5 and its value is 10, but the cell at capacity 10 is 20. Two copies of item 1 give the 20.

The row for item 4 is 100 at capacity 6 and 150 at capacity 9. These values are two and three copies of item 4.

The upward loop compiles, runs, and returns a number that looks correct. But the number is the answer to a different problem.

The figure runs the one-row version in both directions. Select a direction, and compare the last cell after each item.

*Figure: One row of 11 cells, rewritten for each of 5 items. A downward loop ends at 105, and an upward loop ends at 150. Select a direction and step through the items. The two rows differ first after item 1, at room 10: 10 downward and 20 upward.*

```zig
/// The unbounded knapsack. This function does not use code from `rollUp`,
/// thus it can check `rollUp`.
///
/// The capacity loop is outside and the item loop is inside. Thus the order
/// of the loops is different from the order in the function that it checks.
fn bestUnbounded(items: []const Item, cap: u32) u64 {
    var best: [max_cap + 1]u64 = @splat(0);
    for (1..cap + 1) |c| {
        for (items) |item| {
            if (item.weight <= c) best[c] = @max(best[c], item.value + best[c - item.weight]);
        }
    }
    return best[cap];
}
```

*Quoted from the source: `bestUnbounded` from `snippets/23-competitive/knapsack.zig`.*

The different problem is the unbounded knapsack. In the unbounded knapsack, you can take each item any number of times. `bestUnbounded` solves it with the loops in the opposite order: the capacity outside and the items inside.

```
  the unbounded knapsack, any item any number of times, gives 150 -> agree true
```

Thus, when a problem lets you take an item more than one time, the upward loop is correct. Before you select the direction, find "each item at most once" or "unlimited supply" in the problem statement.

## The cost

The table has `(n + 1) * (W + 1)` cells, where `W` is the capacity. Each cell needs a constant quantity of work. Thus the time is O(n * W). The full table uses O(n * W) memory, and the single row uses O(W).

Compare this cost with the 2^n subsets. For 100 items and a capacity of 10,000, the table has approximately one million cells. The number of subsets is approximately 10^30.

But `W` causes a problem. `W` is a number from the input, not the length of something. The input needs only some digits for `W`, but the table needs `W + 1` columns. A capacity of 1,000,000,000 needs ten characters in the input, but one billion columns in the row.

Thus the name for this time is pseudo-polynomial. The time is polynomial in the value of `W`, not in the size of the input.

Check the limits before you use this table:

- If `W` is a maximum of approximately 10^5 or 10^6, the table fits.
- If `W` can be 10^9 and the values are small, the usual method is to change the roles. Use the total value as the index of the table, and store the least weight that gets that value.

## The width of a total

The program reads the weights and values as `u32`. Each total in the program is `u64`. A total is a sum of a maximum of `n` values. A sum can become too large for the type of the numbers that it adds.

```
the width of a total
  u32 holds up to 4294967295
  100 items of value 1000000000 add up to 100000000000
```

Each of a hundred values of 10^9 fits in `u32`. The sum of the values does not fit.

In a Debug or ReleaseSafe build, that addition causes a panic. In ReleaseFast, the addition is illegal behaviour, and the program can continue with a wrong total.

[Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) tells what Zig does when an addition overflows.

For a contest, multiply the largest possible value by the number of items. Then select a type that can hold the product.
