# Sliding Window

> One addition and one subtraction instead of a new sum, the window that grows and shrinks, and the count that shows the total stays linear.

The example uses ten numbers and two questions about them:

1. What is the largest sum of four consecutive values?
2. What is the shortest consecutive range with a sum of 19 or more?

The two problems use a contiguous part of the array. A sliding window solves them with two indices that move from left to right.

The trace below shows the window at each step. Each line also shows the value that entered, the value that left, and the current sum.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The first line has the values. The second line has the window width
/// and the target for the second half of the program.
const input =
    \\2 7 1 9 4 3 8 5 6 2
    \\4 19
;

/// A second array, for the case that the window with a variable size gets
/// wrong.
///
/// One negative value is sufficient. `2 + 3` gets to 5 with two values. The
/// window never examines that pair, because it shrinks only a window that it
/// already made larger than that pair.
const with_a_negative = [_]i32{ 2, -1, 2, 3 };

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

/// Half-open: `items[span.lo..span.hi]` is the window, and `span.hi` is one
/// position after the last value. The binary search chapter uses the same
/// convention.
const Span = struct {
    lo: usize,
    hi: usize,

    fn len(self: Span) usize {
        return self.hi - self.lo;
    }
};

/// The largest sum of `k` consecutive values, from the full sum of each window.
///
/// `adds` counts the additions, because this function shows the cost. Each
/// of the `n - k + 1` windows costs `k` additions. Thus the work increases
/// with the product. A wide window on a long array does much repeated work.
fn resumMaxWindow(items: []const i32, k: usize, adds: *usize) ?i64 {
    if (k == 0 or k > items.len) return null;
    var best: i64 = std.math.minInt(i64);
    for (0..items.len - k + 1) |lo| {
        var sum: i64 = 0;
        for (items[lo..][0..k]) |value| {
            sum += value;
            adds.* += 1;
        }
        best = @max(best, sum);
    }
    return best;
}

/// The same answer, from one addition and one subtraction for each step.
///
/// Two windows one step apart are different by two values: the value that
/// entered on the right and the value that left on the left. All the values
/// between them are in the two sums. Thus a second addition of these values
/// repeats work. Add the first window, then keep the total and change it.
///
/// Use `i64`, not `i32`. Ten small values fit in the two types. A contest
/// array of a hundred thousand values near the limit of `i32` does not fit.
fn slidingMaxWindow(items: []const i32, k: usize, adds: *usize) ?i64 {
    if (k == 0 or k > items.len) return null;
    var sum: i64 = 0;
    for (items[0..k]) |value| {
        sum += value;
        adds.* += 1;
    }
    var best = sum;
    for (k..items.len) |hi| {
        sum += items[hi]; // enters on the right
        sum -= items[hi - k]; // leaves on the left
        adds.* += 2;
        best = @max(best, sum);
    }
    return best;
}

/// The shortest run of values with a sum of `target` or more.
///
/// The right edge grows by one value on each pass. The left edge moves only
/// while the window satisfies the condition. Each window on the path of the
/// left edge is a candidate. `lo` never moves backwards. Thus each index
/// enters one time and leaves a maximum of one time. The inner loop cannot
/// run more than `items.len` times in the full call.
///
/// The shrink rule needs non-negative values. The removal of a value from the
/// left must not make the sum larger. If it can, a window that failed the
/// condition at one step can satisfy the condition again later.
fn shortestAtLeast(items: []const i32, target: i64, moves: *usize) ?Span {
    var lo: usize = 0;
    var sum: i64 = 0;
    var best: ?Span = null;
    for (items, 0..) |value, hi| {
        sum += value;
        moves.* += 1;
        while (sum >= target) {
            const span: Span = .{ .lo = lo, .hi = hi + 1 };
            if (best == null or span.len() < best.?.len()) best = span;
            sum -= items[lo];
            lo += 1;
            moves.* += 1;
        }
    }
    return best;
}

/// The same answer, from each start index in sequence.
///
/// This function is quadratic. The outer loop sets a start. The inner loop
/// makes the range longer until the sum gets to the target. The next start
/// uses nothing from the previous start. `sums` counts the additions. Thus
/// you can compare the two numbers, and you do not have to assume them.
fn everyStartAtLeast(items: []const i32, target: i64, sums: *usize) ?Span {
    var best: ?Span = null;
    for (0..items.len) |lo| {
        var sum: i64 = 0;
        for (lo..items.len) |hi| {
            sum += items[hi];
            sums.* += 1;
            if (sum >= target) {
                const span: Span = .{ .lo = lo, .hi = hi + 1 };
                if (best == null or span.len() < best.?.len()) best = span;
                break;
            }
        }
    }
    return best;
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

/// The array, with the current window shown in it.
///
/// Four characters for each value: a bracket or a space, the value in two
/// characters, a bracket or a space. All rows align. Thus you can see the
/// window move. You do not have to calculate it from two indices.
fn writeWindow(out: *std.Io.Writer, items: []const i32, span: Span) !void {
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

/// One trace row: a label, three counters, then the window.
///
/// A counter of `null` prints a dot. The first row of the fixed trace needs
/// the dot. The trace of the shortest run also needs it before it has an
/// answer.
fn writeRow(
    out: *std.Io.Writer,
    label: []const u8,
    a: ?i64,
    b: ?i64,
    c: ?i64,
    items: []const i32,
    span: Span,
) !void {
    try out.print("  {s: <8}", .{label});
    for ([_]?i64{ a, b, c }) |maybe| {
        if (maybe) |value| try writeCell(out, value, 6) else try out.writeAll("     .");
    }
    try out.writeAll("  ");
    try writeWindow(out, items, span);
    try out.writeByte('\n');
}

/// `slidingMaxWindow`, but it prints the window at each step.
///
/// This function is separate, thus the function above keeps the shape that you
/// can copy into a solution. The run below checks that the two functions give
/// the same result. It does not assume that they do.
fn traceSlidingMaxWindow(out: *std.Io.Writer, items: []const i32, k: usize) !i64 {
    try out.writeAll("  move     enter leave   sum  window\n");
    var sum: i64 = 0;
    for (items[0..k]) |value| sum += value;
    var best = sum;
    try writeRow(out, "first", null, null, sum, items, .{ .lo = 0, .hi = k });
    for (k..items.len) |hi| {
        const entering = items[hi];
        const leaving = items[hi - k];
        sum += entering;
        sum -= leaving;
        best = @max(best, sum);
        try writeRow(out, "slide", entering, leaving, sum, items, .{ .lo = hi - k + 1, .hi = hi + 1 });
    }
    return best;
}

/// `shortestAtLeast`, but it prints a row for each move.
///
/// A `grow` row shows the value that entered and the window after it. A
/// `shrink` row shows the window that satisfied the condition and the value
/// that leaves next. Thus the page shows the candidate that the loop recorded.
fn traceShortestAtLeast(out: *std.Io.Writer, items: []const i32, target: i64) !?Span {
    try out.writeAll("  move     value   sum   len  window\n");
    var lo: usize = 0;
    var sum: i64 = 0;
    var best: ?Span = null;
    for (items, 0..) |value, hi| {
        sum += value;
        try writeRow(out, "grow", value, sum, @intCast(hi + 1 - lo), items, .{ .lo = lo, .hi = hi + 1 });
        while (sum >= target) {
            const span: Span = .{ .lo = lo, .hi = hi + 1 };
            if (best == null or span.len() < best.?.len()) best = span;
            try writeRow(out, "shrink", items[lo], sum, @intCast(span.len()), items, span);
            sum -= items[lo];
            lo += 1;
        }
    }
    return best;
}

/// Print a span as the values in it, or tell that there is no answer.
fn writeSpan(out: *std.Io.Writer, items: []const i32, maybe: ?Span) !void {
    const span = maybe orelse {
        try out.writeAll("no run reaches the target\n");
        return;
    };
    try out.print("items[{d}..{d}], {d} values summing to ", .{ span.lo, span.hi, span.len() });
    var sum: i64 = 0;
    for (items[span.lo..span.hi]) |value| sum += value;
    try out.print("{d}\n", .{sum});
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    var param_storage: [2]i32 = undefined;
    const values = try readRow(&reader, &value_storage);
    const params = try readRow(&reader, &param_storage);
    const k: usize = @intCast(params[0]);
    const target: i64 = params[1];

    try out.print("{d} values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // A fixed window. The loop changes the sum. It does not calculate the sum
    // again.
    try out.print("largest sum of {d} consecutive values\n", .{k});
    const traced = try traceSlidingMaxWindow(out, values, k);
    var sliding_adds: usize = 0;
    var resum_adds: usize = 0;
    const rolled = slidingMaxWindow(values, k, &sliding_adds).?;
    const resummed = resumMaxWindow(values, k, &resum_adds).?;
    try out.print("  best {d}, traced {d}, re-summed {d}\n", .{ rolled, traced, resummed });
    try out.print(
        "  {d} additions sliding, {d} re-summing every window\n\n",
        .{ sliding_adds, resum_adds },
    );

    // A window that changes size. The right edge grows, and the left edge
    // shrinks.
    try out.print("shortest run of values summing to {d} or more\n", .{target});
    const shortest = try traceShortestAtLeast(out, values, target);
    try out.writeAll("  answer: ");
    try writeSpan(out, values, shortest);

    var moves: usize = 0;
    var starts: usize = 0;
    const windowed = shortestAtLeast(values, target, &moves);
    const brute = everyStartAtLeast(values, target, &starts);
    try out.print(
        "  window and every-start agree -> {}\n",
        .{windowed.?.len() == brute.?.len()},
    );

    // The amortised argument, checked with two numbers. Each index enters the
    // window one time and leaves a maximum of one time. Thus the moves cannot
    // be more than 2n, for all possible runs of the inner loop.
    try out.print(
        "  {d} moves over {d} values, ceiling 2n = {d}\n",
        .{ moves, values.len, 2 * values.len },
    );
    try out.print("  {d} additions to try every starting index instead\n\n", .{starts});

    // The shrink rule needs a sum that does not increase when a value leaves on
    // the left.
    try out.writeAll("the same window on an array with a negative value\n");
    try out.writeAll("  val ");
    for (&with_a_negative) |v| try writeCell(out, v, 4);
    try out.writeAll("\n");
    var ignored: usize = 0;
    var also_ignored: usize = 0;
    try out.writeAll("  window says      ");
    try writeSpan(out, &with_a_negative, shortestAtLeast(&with_a_negative, 5, &ignored));
    try out.writeAll("  every start says ");
    try writeSpan(out, &with_a_negative, everyStartAtLeast(&with_a_negative, 5, &also_ignored));

    // The negative value has no effect on the fixed window. The fixed window
    // never selects which values to keep.
    var negative_adds: usize = 0;
    try out.print(
        "  largest sum of 2 consecutive values is still {d}\n",
        .{slidingMaxWindow(&with_a_negative, 2, &negative_adds).?},
    );

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.sliding-window`)*

## Calculate each window again

```zig
/// The largest sum of `k` consecutive values, from the full sum of each window.
///
/// `adds` counts the additions, because this function shows the cost. Each
/// of the `n - k + 1` windows costs `k` additions. Thus the work increases
/// with the product. A wide window on a long array does much repeated work.
fn resumMaxWindow(items: []const i32, k: usize, adds: *usize) ?i64 {
    if (k == 0 or k > items.len) return null;
    var best: i64 = std.math.minInt(i64);
    for (0..items.len - k + 1) |lo| {
        var sum: i64 = 0;
        for (items[lo..][0..k]) |value| {
            sum += value;
            adds.* += 1;
        }
        best = @max(best, sum);
    }
    return best;
}
```

*Quoted from the source: `resumMaxWindow` from `snippets/23-competitive/sliding-window.zig`.*

A simple solution calculates the sum of each possible window from the start. This solution gives the correct answer.

For a window size of four, there are seven possible windows in an array of ten values. Each window needs four additions.

The problem is the quantity of repeated work. There are `n - k + 1` windows, and each window needs `k` additions. Thus the time complexity is `O(n * k)`.

For 200,000 values with a window size of 1,000, the result is approximately 200 million additions. Most of these additions are not necessary.

Two adjacent windows share `k - 1` values. Do not add these values again. Keep the previous sum, and change the sum only for the two values that are different.

## Use one addition and one subtraction

```zig
/// The same answer, from one addition and one subtraction for each step.
///
/// Two windows one step apart are different by two values: the value that
/// entered on the right and the value that left on the left. All the values
/// between them are in the two sums. Thus a second addition of these values
/// repeats work. Add the first window, then keep the total and change it.
///
/// Use `i64`, not `i32`. Ten small values fit in the two types. A contest
/// array of a hundred thousand values near the limit of `i32` does not fit.
fn slidingMaxWindow(items: []const i32, k: usize, adds: *usize) ?i64 {
    if (k == 0 or k > items.len) return null;
    var sum: i64 = 0;
    for (items[0..k]) |value| {
        sum += value;
        adds.* += 1;
    }
    var best = sum;
    for (k..items.len) |hi| {
        sum += items[hi]; // enters on the right
        sum -= items[hi - k]; // leaves on the left
        adds.* += 2;
        best = @max(best, sum);
    }
    return best;
}
```

*Quoted from the source: `slidingMaxWindow` from `snippets/23-competitive/sliding-window.zig`.*

First, calculate the sum of the first window in the usual way. After that, each new window is different from the previous window by only two values:

- One value enters from the right.
- One value leaves from the left.

Thus you do not calculate the full sum again. Change the current sum in two steps:

1. Add the new value.
2. Subtract the old value.

The first four windows are:

```
  move     enter leave   sum  window
  first        .     .    19  [ 2   7   1   9]  4   3   8   5   6   2
  slide        4     2    21    2 [ 7   1   9   4]  3   8   5   6   2
  slide        3     7    17    2   7 [ 1   9   4   3]  8   5   6   2
  slide        8     1    24    2   7   1 [ 9   4   3   8]  5   6   2
```

In the third row, 3 enters the window and 7 leaves the window. The sum changes from 21 to 17. The program does not add the values in the middle again.

The program also counts the additions in the two methods:

```
  16 additions sliding, 28 re-summing every window
```

For ten values, the difference is small. The difference becomes larger when the array becomes larger.

The sliding version does approximately `2n - k` additions and subtractions. The version that calculates each sum again does `k(n - k + 1)` additions. Thus the sliding version is O(n), and the calculation of each window from the start is O(nk).

The total uses `i64`, but each value is `i32`. The sum of many `i32` values can be too large for an `i32`. A wider type for the total prevents this overflow.

## Use a window that changes size

```zig
/// The shortest run of values with a sum of `target` or more.
///
/// The right edge grows by one value on each pass. The left edge moves only
/// while the window satisfies the condition. Each window on the path of the
/// left edge is a candidate. `lo` never moves backwards. Thus each index
/// enters one time and leaves a maximum of one time. The inner loop cannot
/// run more than `items.len` times in the full call.
///
/// The shrink rule needs non-negative values. The removal of a value from the
/// left must not make the sum larger. If it can, a window that failed the
/// condition at one step can satisfy the condition again later.
fn shortestAtLeast(items: []const i32, target: i64, moves: *usize) ?Span {
    var lo: usize = 0;
    var sum: i64 = 0;
    var best: ?Span = null;
    for (items, 0..) |value, hi| {
        sum += value;
        moves.* += 1;
        while (sum >= target) {
            const span: Span = .{ .lo = lo, .hi = hi + 1 };
            if (best == null or span.len() < best.?.len()) best = span;
            sum -= items[lo];
            lo += 1;
            moves.* += 1;
        }
    }
    return best;
}
```

*Quoted from the source: `shortestAtLeast` from `snippets/23-competitive/sliding-window.zig`.*

The second problem is different. The answer is the shortest consecutive range with a sum that is equal to or more than the target. The window size is not fixed. Thus the window must grow and shrink.

The window changes in two ways:

- The right edge moves forward and adds values to the sum.
- When the sum gets to the target, the left edge moves forward to make the window smaller. The left edge continues to move while the window satisfies the condition.

A `shrink` row in the trace shows a valid window and the value that the next step removes:

```
  grow         6    22     4    2   7   1   9   4 [ 3   8   5   6]  2
  shrink       3    22     4    2   7   1   9   4 [ 3   8   5   6]  2
  shrink       8    19     3    2   7   1   9   4   3 [ 8   5   6]  2
  grow         2    13     3    2   7   1   9   4   3   8 [ 5   6   2]
```

The addition of 6 makes the sum 22. This sum is equal to or more than the target, thus the current window is valid. The length of the window is four.

Then the loop removes 3 from the left. The values 8, 5 and 6 stay in the window, and their sum is 19. This sum also gets to the target. Thus the loop has a shorter valid window, with a length of three.

Next, the loop removes 8. The sum becomes less than the target, thus the left edge stops. The right edge starts to move again.

The final answer is:

```
  answer: items[6..9], 3 values summing to 19
```

The loop records the current window before it removes the left value. If the loop removes the value first and checks the window after the removal, the loop can miss a valid candidate.

The figure plays the 17 rows of the trace. The outline is the window. It grows to the right until the sum gets to 19, then it shrinks from the left. At the end, a dashed outline marks the answer.

*Figure: Ten values, 2, 7, 1, 9, 4, 3, 8, 5, 6, 2, with an outline for the window. The outline grows to the right and shrinks from the left. The trace from the program above, one row for each step. The outline is the window, and the dashed outline at the end is the answer.*

## Why the inner loop is still O(n)

```zig
/// The same answer, from each start index in sequence.
///
/// This function is quadratic. The outer loop sets a start. The inner loop
/// makes the range longer until the sum gets to the target. The next start
/// uses nothing from the previous start. `sums` counts the additions. Thus
/// you can compare the two numbers, and you do not have to assume them.
fn everyStartAtLeast(items: []const i32, target: i64, sums: *usize) ?Span {
    var best: ?Span = null;
    for (0..items.len) |lo| {
        var sum: i64 = 0;
        for (lo..items.len) |hi| {
            sum += items[hi];
            sums.* += 1;
            if (sum >= target) {
                const span: Span = .{ .lo = lo, .hi = hi + 1 };
                if (best == null or span.len() < best.?.len()) best = span;
                break;
            }
        }
    }
    return best;
}
```

*Quoted from the source: `everyStartAtLeast` from `snippets/23-competitive/sliding-window.zig`.*

The `while` loop inside the `for` loop is still O(n). [The Monotonic Stack](https://www.ziglang.in/learn/competitive-programming/monotonic-stack/) gives the reason.

Each value enters the window one time and leaves the window a maximum of one time. Here, `lo` never moves backwards. Thus the two edges together move a maximum of approximately `2n` times.

The counts for this example are:

```
  17 moves over 10 values, ceiling 2n = 20
  34 additions to try every starting index instead
```

The window grows ten times and shrinks seven times. The total is 17 moves.

The other version starts a new sum at each possible start position. It repeats the work that the earlier start positions did. Thus that version is quadratic.

The sliding-window version uses the current state again and never resets `lo`.

## When the shrink rule fails

```zig
/// A second array, for the case that the window with a variable size gets
/// wrong.
///
/// One negative value is sufficient. `2 + 3` gets to 5 with two values. The
/// window never examines that pair, because it shrinks only a window that it
/// already made larger than that pair.
const with_a_negative = [_]i32{ 2, -1, 2, 3 };
```

*Quoted from the source: `with_a_negative` from `snippets/23-competitive/sliding-window.zig`.*

The window with a variable size above needs one property. When the loop removes a value from the left, the sum must stay the same or become smaller.

- If all values are non-negative, this property is true.
- If the input can have negative values, this property is not true.

Look at this input:

```
  val    2  -1   2   3
  window says      items[0..4], 4 values summing to 6
  every start says items[2..4], 2 values summing to 5
```

The sum of the full array is 6, thus the window gets to the target. Then the algorithm removes the first value, 2. The sum becomes 4. The sum is now less than the target, thus the left edge stops.

But the window still contains `-1`. If the loop also removes that negative value, the last two values `2` and `3` give a shorter valid window with a sum of 5. The usual shrink rule never gets to that window. Thus the sliding-window solution with a variable size is not correct for arbitrary negative values.

The brute-force version checks each start position and finds the correct answer, but it needs O(n²) time.

The fixed-size sliding window does not have this problem. The fixed window does not make decisions from an increase or a decrease of the sum. It only adds the value that enters and removes the value that leaves. Thus the fixed window is also correct with negative values:

```
  largest sum of 2 consecutive values is still 5
```

A problem with a contiguous answer does not always mean that a sliding window will work. For a sliding window with a variable size, the condition must usually change in a predictable way when the window grows or shrinks.

For example, with non-negative numbers:

- An added value cannot make the sum smaller.
- A removed value cannot make the sum larger.

These two facts give a safe rule for when to grow and when to shrink. Other examples are a limit on the number of different characters in a window, or on the number of forbidden values in a window.

If the condition does not have this property, a different technique can be necessary, for example prefix sums, a deque, or a heap.

Two indices that start at the two ends of a sorted array and move towards each other use a different pattern. [Two Pointers](https://www.ziglang.in/learn/competitive-programming/two-pointers/) tells about that method.
