# Prefix Sums and Difference Arrays

> One subtraction instead of a loop, an extra cell for index 0, and the same method in reverse for range updates.

A range-sum query asks for the total of one part of an array. This problem has many of these queries.

For one query, a loop can add the values in the range. This method is satisfactory when there are only a small number of queries. But with 100,000 values and 100,000 queries, a loop over each range can need billions of additions.

A prefix sum prepares the array one time. After that, one subtraction gives the sum of a range.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The first line has the values. The second line has five half-open
/// ranges as `lo hi` pairs. The third line has three range updates as
/// `lo hi delta`.
const input =
    \\3 1 4 1 5 9 2 6
    \\0 3 2 5 1 8 4 4 0 8
    \\0 3 5 2 6 -1 4 8 10
;

/// Read one line of whitespace-separated integers into `out`.
///
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. On a judge, give
/// the function a reader on stdin. The function does not change.
fn readRow(reader: *std.Io.Reader, out: []i32) ![]i32 {
    const line = (try reader.takeDelimiter('\n')) orelse return error.MissingRow;
    var count: usize = 0;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        if (count == out.len) return error.RowTooLong;
        out[count] = try std.fmt.parseInt(i32, field, 10);
        count += 1;
    }
    return out[0..count];
}

/// Half-open: `items[span.lo..span.hi]` is the range, and `span.hi` is one
/// position after the last value. The binary search chapter uses the same
/// convention.
const Span = struct {
    lo: usize,
    hi: usize,

    fn len(self: Span) usize {
        return self.hi - self.lo;
    }
};

/// `out[i]` becomes the sum of the first `i` values. Thus `out` is one cell
/// longer than `items`. The extra cell lets the code read a range that starts
/// at index 0 in the same way as all other ranges.
///
/// Use `i64`, not `i32`. Eight small values fit in the two types. A hundred
/// thousand values near the top of `i32` do not fit. Thus the totals use the
/// wider type. `adds` counts the additions, because the build cost helps you
/// decide if a prefix array is cheaper than a loop.
fn buildPrefix(items: []const i32, out: []i64, adds: *usize) []i64 {
    out[0] = 0;
    for (items, 0..) |value, i| {
        out[i + 1] = out[i] + value;
        adds.* += 1;
    }
    return out[0 .. items.len + 1];
}

/// The sum of `items[lo..hi]`, from two reads and a subtraction.
///
/// `pre[hi]` counts all values below `hi`, and `pre[lo]` counts all values
/// below `lo`. Thus the difference is exactly the part between them.
/// `lo == hi` gives zero without a branch. `lo == 0` reads `pre[0]`, and the
/// extra cell already set `pre[0]` to zero.
fn rangeSum(pre: []const i64, span: Span) i64 {
    return pre[span.hi] - pre[span.lo];
}

/// The same sum, from the addition of each value.
///
/// This function lets you compare the two results. You do not have to assume
/// that they agree. It also lets you compare its count of additions with the
/// count from `buildPrefix`.
fn rangeSumByLoop(items: []const i32, span: Span, adds: *usize) i64 {
    var sum: i64 = 0;
    for (items[span.lo..span.hi]) |value| {
        sum += value;
        adds.* += 1;
    }
    return sum;
}

/// Record "add `delta` to every value in `items[lo..hi]`" in two writes.
///
/// `diff` is one cell longer than the array that it describes. The reason is
/// the same as for the prefix array. An update that goes to the last index
/// writes its end mark at `items.len`, and that cell must exist.
///
/// The cost does not change with the width of the range. A range on the full
/// array is two writes, and a range on one value is also two writes.
fn applyRange(diff: []i64, span: Span, delta: i64) void {
    diff[span.lo] += delta;
    diff[span.hi] -= delta;
}

/// The cumulative sum of `diff`. This sum gives the values that `diff`
/// recorded.
///
/// The last cell of `diff` never adds a value to the output. The last cell
/// cancels the deltas that started. Thus after the pass, the total is zero
/// again.
fn accumulate(diff: []const i64, out: []i32) []i32 {
    var running: i64 = 0;
    for (diff[0 .. diff.len - 1], 0..) |value, i| {
        running += value;
        out[i] = @intCast(running);
    }
    return out[0 .. diff.len - 1];
}

/// The difference between each value and the value before it.
///
/// The inverse of `accumulate`. Use this function on an array, then use
/// `accumulate` on the result. The output is the original array.
/// `out[items.len]` closes the array, because it subtracts the last value.
fn difference(items: []const i32, out: []i64) []i64 {
    var previous: i64 = 0;
    for (items, 0..) |value, i| {
        out[i] = value - previous;
        previous = value;
    }
    out[items.len] = -previous;
    return out[0 .. items.len + 1];
}

/// Apply each update in the slow way: write each cell of each range.
///
/// The difference array must agree with this reference. The cost of this
/// function is the sum of the range widths. The two writes for each update
/// replace this cost.
fn applyRangesDirectly(out: []i32, spans: []const Span, deltas: []const i64) []i32 {
    @memset(out, 0);
    for (spans, deltas) |span, delta| {
        for (out[span.lo..span.hi]) |*cell| cell.* += @intCast(delta);
    }
    return out;
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the columns are easy to read.
fn writeCell(out: *std.Io.Writer, value: i64, width: usize) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The array, with one range shown in it.
///
/// Four characters for each value: a bracket or a space, the value in two
/// characters, a bracket or a space. An empty range shows no brackets. The
/// row for `[4,4)` on the page shows this result.
fn writeRange(out: *std.Io.Writer, items: []const i32, span: Span) !void {
    const inside = span.lo < span.hi;
    for (items, 0..) |value, i| {
        try out.writeByte(if (inside and i == span.lo) '[' else ' ');
        try writeCell(out, value, 2);
        const closing: u8 = if (inside and i + 1 == span.hi) ']' else ' ';
        // No space at the end of a row. CI compares the output with the expected
        // output byte for byte, and a space that you cannot see is easy to get
        // wrong.
        if (closing == ' ' and i + 1 == items.len) break;
        try out.writeByte(closing);
    }
}

/// A row of `i64` cells with a label. Each cell is four characters.
///
/// The label field is 13 characters wide. Thus the update trace aligns under
/// a header of column numbers. Only this alignment shows which two cells a
/// range update changed.
fn writeWideRow(out: *std.Io.Writer, label: []const u8, cells: []const i64) !void {
    try out.print("  {s: <13}", .{label});
    for (cells) |value| try writeCell(out, value, 4);
    try out.writeByte('\n');
}

/// A row of `i32` cells with a label. Each cell is four characters.
fn writeNarrowRow(out: *std.Io.Writer, label: []const u8, cells: []const i32) !void {
    try out.print("  {s: <4}", .{label});
    for (cells) |value| try writeCell(out, value, 4);
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    var query_storage: [64]i32 = undefined;
    var update_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);
    const query_fields = try readRow(&reader, &query_storage);
    const update_fields = try readRow(&reader, &update_storage);

    var query_buf: [16]Span = undefined;
    var query_count: usize = 0;
    var q: usize = 0;
    while (q + 1 < query_fields.len) : (q += 2) {
        query_buf[query_count] = .{
            .lo = @intCast(query_fields[q]),
            .hi = @intCast(query_fields[q + 1]),
        };
        query_count += 1;
    }
    const queries = query_buf[0..query_count];

    var update_span_buf: [16]Span = undefined;
    var update_delta_buf: [16]i64 = undefined;
    var update_count: usize = 0;
    var u: usize = 0;
    while (u + 2 < update_fields.len) : (u += 3) {
        update_span_buf[update_count] = .{
            .lo = @intCast(update_fields[u]),
            .hi = @intCast(update_fields[u + 1]),
        };
        update_delta_buf[update_count] = update_fields[u + 2];
        update_count += 1;
    }
    const update_spans = update_span_buf[0..update_count];
    const update_deltas = update_delta_buf[0..update_count];

    try out.print("{d} values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeByte('\n');
    try writeNarrowRow(out, "val", values);
    try out.writeByte('\n');

    // The build. One pass, one addition for each value, and one cell more than
    // the array that it summarises.
    var build_adds: usize = 0;
    var prefix_storage: [65]i64 = undefined;
    const pre = buildPrefix(values, &prefix_storage, &build_adds);
    try out.print("the prefix array holds {d} cells for {d} values\n", .{ pre.len, values.len });
    try out.writeAll("  idx ");
    for (0..pre.len) |i| try out.print("{d:>4}", .{i});
    try out.writeByte('\n');
    try out.writeAll("  pre ");
    for (pre) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // Each query is two reads and a subtraction, for all sizes of range.
    try out.print("{d} range sums, each one a subtraction\n", .{queries.len});
    try out.writeAll("  range   pre[hi] pre[lo]   sum  values\n");
    var loop_adds: usize = 0;
    var all_agree = true;
    for (queries) |span| {
        var label: [16]u8 = undefined;
        const text = try std.mem.print(&label, "[{d},{d})", .{ span.lo, span.hi });
        const fast = rangeSum(pre, span);
        const slow = rangeSumByLoop(values, span, &loop_adds);
        if (fast != slow) all_agree = false;
        try out.print("  {s: <7}", .{text});
        try writeCell(out, pre[span.hi], 8);
        try writeCell(out, pre[span.lo], 8);
        try writeCell(out, fast, 6);
        try out.writeAll("  ");
        try writeRange(out, values, span);
        try out.writeByte('\n');
    }
    try out.print("  every sum matches a loop over the same values -> {}\n\n", .{all_agree});

    // The program pays for the build one time. An array that changes between
    // queries needs a new build each time, and then the loop is cheaper.
    try out.writeAll("what the build costs, against what it saves\n");
    var plan: [40]u8 = undefined;
    const built_once = try std.mem.print(&plan, "build once, then {d} lookups", .{queries.len});
    try out.print("  {s: <28}{d:>4} adds\n", .{ built_once, build_adds });
    try out.print("  {s: <28}{d:>4} adds\n", .{ "rebuild before each lookup", build_adds * queries.len });
    try out.print("  {s: <28}{d:>4} adds\n\n", .{ "no prefix array at all", loop_adds });

    // The opposite direction. Two writes record a change on a full range.
    try out.print("{d} range updates on a difference array\n", .{update_spans.len});
    var diff_storage: [65]i64 = undefined;
    const diff = diff_storage[0 .. values.len + 1];
    @memset(diff, 0);
    try out.print("  {s: <13}", .{"update"});
    for (0..diff.len) |i| try out.print("{d:>4}", .{i});
    try out.writeByte('\n');
    try writeWideRow(out, "start", diff);
    for (update_spans, update_deltas) |span, delta| {
        applyRange(diff, span, delta);
        var label: [24]u8 = undefined;
        const sign: []const u8 = if (delta < 0) "" else "+";
        const text = try std.mem.print(&label, "{s}{d} on [{d},{d})", .{ sign, delta, span.lo, span.hi });
        try writeWideRow(out, text, diff);
    }
    try out.writeByte('\n');

    // One pass reads the totals.
    try out.writeAll("one running sum turns those marks into values\n");
    var totals_storage: [64]i32 = undefined;
    const totals = accumulate(diff, &totals_storage);
    try out.writeAll("  idx ");
    for (0..totals.len) |i| try out.print("{d:>4}", .{i});
    try out.writeByte('\n');
    try writeNarrowRow(out, "tot", totals);
    var direct_storage: [64]i32 = undefined;
    const direct = applyRangesDirectly(direct_storage[0..values.len], update_spans, update_deltas);
    try out.print(
        "  writing every cell of every range agrees -> {}\n",
        .{std.mem.eql(i32, totals, direct)},
    );
    var covered: usize = 0;
    for (update_spans) |span| covered += span.len();
    try out.print(
        "  {d} writes for {d} updates, against {d} cells the slow way\n\n",
        .{ 2 * update_spans.len, update_spans.len, covered },
    );

    // Each operation cancels the other. Thus the round trip checks the two
    // operations.
    try out.writeAll("a running sum undoes a difference\n");
    var gaps_storage: [65]i64 = undefined;
    const gaps = difference(values, &gaps_storage);
    var back_storage: [64]i32 = undefined;
    const back = accumulate(gaps, &back_storage);
    try writeNarrowRow(out, "val", values);
    try out.writeAll("  diff");
    for (gaps) |v| try writeCell(out, v, 4);
    try out.writeByte('\n');
    try writeNarrowRow(out, "back", back);
    try out.print("  back equals val -> {}\n", .{std.mem.eql(i32, values, back)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.prefix-sums`)*

## Build the prefix array

```zig
/// `out[i]` becomes the sum of the first `i` values. Thus `out` is one cell
/// longer than `items`. The extra cell lets the code read a range that starts
/// at index 0 in the same way as all other ranges.
///
/// Use `i64`, not `i32`. Eight small values fit in the two types. A hundred
/// thousand values near the top of `i32` do not fit. Thus the totals use the
/// wider type. `adds` counts the additions, because the build cost helps you
/// decide if a prefix array is cheaper than a loop.
fn buildPrefix(items: []const i32, out: []i64, adds: *usize) []i64 {
    out[0] = 0;
    for (items, 0..) |value, i| {
        out[i + 1] = out[i] + value;
        adds.* += 1;
    }
    return out[0 .. items.len + 1];
}
```

*Quoted from the source: `buildPrefix` from `snippets/23-competitive/prefix-sums.zig`.*

The prefix array keeps cumulative sums. `pre[i]` is the sum of the first `i` values. Because of this definition, the prefix array has one more cell than the original array.

- `pre[0]` is the sum of zero values. Thus `pre[0]` is 0.
- `pre[1]` contains the first value.
- `pre[2]` contains the sum of the first two values.
- The other cells continue in the same way.

The prefix array for the example input is:

```
  idx    0   1   2   3   4   5   6   7
  val    3   1   4   1   5   9   2   6

the prefix array holds 9 cells for 8 values
  idx    0   1   2   3   4   5   6   7   8
  pre    0   3   4   8   9  14  23  25  31
```

The prefix indices are easier to understand as boundaries. `pre[3]` is 8, because `pre[3]` holds the three values before index 3: `3 + 1 + 4`. `pre[0]` is the boundary before the first value. `pre[8]` is the boundary after the last value.

Without the extra cell at index 0, a range that starts at index 0 needs a special case. For example, code that uses `pre[lo - 1]` fails when `lo` is 0. The extra zero at the start lets the same formula work for all ranges.

## Calculate a range sum with one subtraction

```zig
/// The sum of `items[lo..hi]`, from two reads and a subtraction.
///
/// `pre[hi]` counts all values below `hi`, and `pre[lo]` counts all values
/// below `lo`. Thus the difference is exactly the part between them.
/// `lo == hi` gives zero without a branch. `lo == 0` reads `pre[0]`, and the
/// extra cell already set `pre[0]` to zero.
fn rangeSum(pre: []const i64, span: Span) i64 {
    return pre[span.hi] - pre[span.lo];
}
```

*Quoted from the source: `rangeSum` from `snippets/23-competitive/prefix-sums.zig`.*

Use the half-open range `[lo, hi)`:

- `pre[hi]` contains the sum of all values before `hi`.
- `pre[lo]` contains the sum of all values before `lo`.

Thus the range sum is `pre[hi] - pre[lo]`. The values before `lo` are in the two prefix values, and the subtraction removes them.

The program calculates five ranges:

```
  range   pre[hi] pre[lo]   sum  values
  [0,3)         8       0     8  [ 3   1   4]  1   5   9   2   6
  [2,5)        14       4    10    3   1 [ 4   1   5]  9   2   6
  [1,8)        31       3    28    3 [ 1   4   1   5   9   2   6]
  [4,4)         9       9     0    3   1   4   1   5   9   2   6
  [0,8)        31       0    31  [ 3   1   4   1   5   9   2   6]
```

The cost does not change with the width of the range. The range `[0,3)` contains three values, and the range `[1,8)` contains seven values. The two queries use the same two reads from the prefix array and one subtraction.

The empty range `[4,4)` also works: `pre[4] - pre[4] = 0`. A special case is not necessary. The full array is `pre[8] - pre[0]`, which gives 31.

Half-open ranges also agree with usual Zig slices. If you use an inclusive range, the formula becomes `pre[hi + 1] - pre[lo]`. The method is the same.

## When to use prefix sums

```zig
/// The same sum, from the addition of each value.
///
/// This function lets you compare the two results. You do not have to assume
/// that they agree. It also lets you compare its count of additions with the
/// count from `buildPrefix`.
fn rangeSumByLoop(items: []const i32, span: Span, adds: *usize) i64 {
    var sum: i64 = 0;
    for (items[span.lo..span.hi]) |value| {
        sum += value;
        adds.* += 1;
    }
    return sum;
}
```

*Quoted from the source: `rangeSumByLoop` from `snippets/23-competitive/prefix-sums.zig`.*

The build of the prefix array takes O(n). After the build, each range query takes O(1). Thus prefix sums are useful when the array does not change and the program must answer many queries.

The costs for this small example are:

```
  build once, then 5 lookups     8 adds
  rebuild before each lookup    40 adds
  no prefix array at all        21 adds
```

One build of the prefix array needs eight additions. After that, the five queries use only subtraction. For an array this small, a loop over each range needs only 21 additions. Thus the difference is not large. The advantage becomes larger with many values and many queries.

Prefix sums also have a limit. If the original array changes, the prefix array is out of date. For example, if the value at index 3 changes, each prefix value after that position can be wrong. A new build of the prefix array costs O(n).

Thus prefix sums are not a good choice when a problem has many updates between its queries. For that type of problem, a Fenwick tree or a segment tree can do both updates and queries in O(log n).

Prefix sums and sliding windows solve different problems:

- A prefix sum can answer arbitrary range queries in any order.
- A sliding window is usually useful when the program examines the ranges in sequence, and each range is almost the same as the next range.

[Sliding Window](https://www.ziglang.in/learn/competitive-programming/sliding-window/) tells about that pattern.

## Use a difference array

```zig
/// Record "add `delta` to every value in `items[lo..hi]`" in two writes.
///
/// `diff` is one cell longer than the array that it describes. The reason is
/// the same as for the prefix array. An update that goes to the last index
/// writes its end mark at `items.len`, and that cell must exist.
///
/// The cost does not change with the width of the range. A range on the full
/// array is two writes, and a range on one value is also two writes.
fn applyRange(diff: []i64, span: Span, delta: i64) void {
    diff[span.lo] += delta;
    diff[span.hi] -= delta;
}
```

*Quoted from the source: `applyRange` from `snippets/23-competitive/prefix-sums.zig`.*

Some problems have many range updates instead of many range queries. For example:

- add 5 to every value in `[0,3)`
- subtract 1 from every value in `[2,6)`
- add 10 to every value in `[4,8)`

The direct method changes each value in each range. That method costs O(width) for each update.

A difference array records each range update with only two writes. The values do not change immediately. Instead, the difference array records where the change starts and where it stops.

The three updates above give this result:

```
  update          0   1   2   3   4   5   6   7   8
  start           0   0   0   0   0   0   0   0   0
  +5 on [0,3)     5   0   0  -5   0   0   0   0   0
  -1 on [2,6)     5   0  -1  -5   0   0   1   0   0
  +10 on [4,8)    5   0  -1  -5  10   0   1   0 -10
```

To add 5 to `[0,3)`, write `+5` at index 0 and `-5` at index 3. Thus the change starts at 0 and stops at 3. Indices 1 and 2 do not need a write.

For the update on `[4,8)`, write `+10` at index 4 and `-10` at index 8. Index 8 is one position after the last array value. The extra position lets an update that goes to the end of the array close correctly.

The difference array does not directly contain the final values. It contains changes, and a later step must add them together.

## Change the differences back to values

```zig
/// The cumulative sum of `diff`. This sum gives the values that `diff`
/// recorded.
///
/// The last cell of `diff` never adds a value to the output. The last cell
/// cancels the deltas that started. Thus after the pass, the total is zero
/// again.
fn accumulate(diff: []const i64, out: []i32) []i32 {
    var running: i64 = 0;
    for (diff[0 .. diff.len - 1], 0..) |value, i| {
        running += value;
        out[i] = @intCast(running);
    }
    return out[0 .. diff.len - 1];
}
```

*Quoted from the source: `accumulate` from `snippets/23-competitive/prefix-sums.zig`.*

To get the final values, calculate a cumulative sum over the difference array. Each difference value changes the cumulative sum from that position to the end.

The result for the three updates above is:

```
  idx    0   1   2   3   4   5   6   7
  tot    5   5   4  -1   9   9  10  10
  writing every cell of every range agrees -> true
  6 writes for 3 updates, against 11 cells the slow way
```

The `+5` at index 0 makes the cumulative sum 5. Indices 1 and 2 have no change, thus the cumulative sum stays at 5. At index 3, the `-5` removes that update. The other range changes work in the same way.

There are three updates, and each update needs two writes. Thus the difference-array version needs six writes. The direct version changes eleven array cells in total, because eleven is the sum of the widths of the three update ranges. For wider ranges, the difference between the two methods becomes larger.

The final `-10` at index 8 is not in the output array, because index 8 is outside the original eight values. The `-10` closes the update after the last value. If the cumulative sum continues through index 8, the cumulative sum becomes zero again. This result is a useful check that the differences are consistent.

The figure plays the three updates, then the running sum, one index at a time. Before the sum, it stops and asks you to predict one value.

*Figure: A difference array of 9 marks. 3 range updates each write two marks, and a running sum turns the marks into 8 values. The updates and the running sum from the program above. The figure stops before the sum and asks you to predict one value.*

## A running sum undoes a difference array

A difference array keeps the change between adjacent values. The difference array for the input array is:

```
  val    3   1   4   1   5   9   2   6
  diff   3  -2   3  -3   4   4  -7   4  -6
  back   3   1   4   1   5   9   2   6
```

The first difference is 3, because the first value changes from an initial 0 to 3. The next difference is `1 - 3 = -2`. The difference after that is `4 - 1 = 3`, and the other differences continue in the same way.

A prefix sum of these differences gives the original values again. Thus the two methods are closely related:

- A prefix array costs O(n) to build. Then each range-sum query costs O(1).
- A difference array records each range update in O(1). The change back to final values costs O(n).

Select the method for the problem:

- If you have many queries and a small number of updates, use prefix sums.
- If you have many range updates and need only the final array after them, use a difference array.
