# The Monotonic Stack

> A stack of the indices still waiting for an answer, and the two counters that show the inner loop is free.

Suppose we have an array and, for every value, we want to find the first larger value to its right.

Some values find a larger value immediately.

Some have to look much further.

Some do not have a larger value to their right at all.

A simple solution is to start at every index and scan to the right until a larger value is found.

That works, but in the worst case it checks almost every pair of values.

A monotonic stack solves the same problem in one pass.

Instead of asking, "What is the answer for this index?", we ask a different question:

"Which earlier indices can the current value answer?"

The stack stores the indices that are still waiting for a larger value.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. One line of values is all the problem needs, and the parser below
/// reads it the way it would read a real file.
const input =
    \\3 1 4 1 5 9 2 6 5 3 7
;

/// The worst array for a scan and the easiest one for the stack.
///
/// Nothing has a greater value to its right, so the scan walks to the end from
/// every index and the stack never pops.
const decreasing = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The mirror of it. The scan stops on its first comparison every time, and the
/// stack pops the index it pushed a moment ago.
const increasing = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

/// Read one line of whitespace-separated integers into `out`.
///
/// Taking a `*std.Io.Reader` rather than the string is the same discipline the
/// networking chapters use for protocols. Point it at stdin on a judge and not
/// a line of it changes.
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

/// The two counters the amortised argument rests on.
///
/// Counting them costs two lines and settles a question that reasoning about
/// the nested loop usually gets wrong.
const Work = struct {
    pushes: usize = 0,
    pops: usize = 0,
};

/// For each index, the index of the first greater value to its right.
///
/// The obvious solution. Fix an index, walk right until something beats it,
/// give up at the end of the array. `comparisons` counts the values looked at,
/// which is the number that grows with the square of the input.
fn scanRight(items: []const i32, out: []?usize, comparisons: *usize) void {
    for (items, 0..) |value, i| {
        out[i] = null;
        for (items[i + 1 ..], i + 1..) |other, j| {
            comparisons.* += 1;
            if (other > value) {
                out[i] = j;
                break;
            }
        }
    }
}

/// The same answers from one pass over the array.
///
/// The stack holds the indices whose answer is still unknown, and it holds them
/// in decreasing order of value. When `value` arrives, every index on the stack
/// with a smaller value has found its answer, and those indices sit together at
/// the top because of the ordering. Pop them, record `i`, push `i`.
///
/// The order is preserved by the loop itself. Everything left after the pops is
/// at least as large as `value`, so putting `i` on top keeps the stack falling
/// from bottom to top.
///
/// `>=` and not `>`. An equal value is not greater, so an index waiting on a 7
/// is not answered by another 7.
///
/// Indices still on the stack when the array runs out are never written, and
/// `out` was filled with null before the loop, so having no answer needs no
/// case of its own.
fn nextGreater(gpa: Allocator, items: []const i32, out: []?usize, work: *Work) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    @memset(out, null);

    for (items, 0..) |value, i| {
        while (stack.last()) |top| {
            if (items[top] >= value) break;
            out[top] = i;
            _ = stack.pop();
            work.pops += 1;
        }
        try stack.append(gpa, i);
        work.pushes += 1;
    }
}

/// The first smaller value to the left, from the same machine.
///
/// Two changes. The comparison flips, so the stack rises from bottom to top
/// instead of falling. And the answer is read off the survivor rather than
/// written into the values popped: after the pops, whatever is still on top is
/// the nearest index to the left holding a smaller value.
fn previousSmaller(gpa: Allocator, items: []const i32, out: []?usize, work: *Work) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    @memset(out, null);

    for (items, 0..) |value, i| {
        while (stack.last()) |top| {
            if (items[top] < value) break;
            _ = stack.pop();
            work.pops += 1;
        }
        out[i] = stack.last();
        try stack.append(gpa, i);
        work.pushes += 1;
    }
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// A value that may be missing, right-aligned. A dot means no answer.
fn writeMaybe(out: *std.Io.Writer, value: ?i32, width: usize) !void {
    if (value) |v| return writeCell(out, v, width);
    try out.splatByteAll(' ', width - 1);
    try out.writeByte('.');
}

/// The stack, bottom to top, as `index:value` pairs.
///
/// Printing the values beside the indices is what makes the ordering visible.
/// A column of bare indices would hide the one property the whole method rests
/// on.
fn writeStack(out: *std.Io.Writer, items: []const i32, indices: []const usize) !void {
    for (indices, 0..) |idx, k| {
        if (k > 0) try out.writeByte(' ');
        try out.print("{d}:{d}", .{ idx, items[idx] });
    }
}

/// The indices resolved by this step, each with the answer it got.
///
/// They all get the same answer, since they were all popped by the same
/// arriving value. Writing it out per index keeps the row readable next to the
/// answers table further down.
fn writeResolved(out: *std.Io.Writer, popped: []const usize, answer: i32, width: usize) !void {
    var used: usize = 0;
    if (popped.len == 0) {
        try out.writeByte('.');
        used = 1;
    }
    for (popped, 0..) |idx, k| {
        if (k > 0) {
            try out.writeAll(", ");
            used += 2;
        }
        var digits: [24]u8 = undefined;
        const text = try std.mem.print(&digits, "{d} -> {d}", .{ idx, answer });
        try out.writeAll(text);
        used += text.len;
    }
    try out.splatByteAll(' ', width - used);
}

/// `nextGreater` with a row printed per incoming value.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two agree rather than trusting it.
/// The last row is also the answer to what happens at the end: whatever the
/// stack is holding then never found a greater value.
fn traceNextGreater(out: *std.Io.Writer, gpa: Allocator, items: []const i32) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);

    try out.writeAll("   i  val  resolved (index -> answer)   stack after (bottom to top)\n");
    for (items, 0..) |value, i| {
        var popped: [16]usize = undefined;
        var count: usize = 0;
        while (stack.last()) |top| {
            if (items[top] >= value) break;
            popped[count] = top;
            count += 1;
            _ = stack.pop();
        }
        try stack.append(gpa, i);

        try writeCell(out, @intCast(i), 4);
        try writeCell(out, value, 5);
        try out.writeAll("  ");
        try writeResolved(out, popped[0..count], value, 28);
        try writeStack(out, items, stack.items);
        try out.writeByte('\n');
    }

    try out.print("  {d} indices never popped: ", .{stack.items.len});
    try writeStack(out, items, stack.items);
    try out.writeByte('\n');
}

/// One row of the cost table: what the scan pays against what the stack pays.
///
/// Both run over the same array, so the two numbers are comparable rather than
/// quoted from different runs. The scan's count is comparisons and the stack's
/// is moves, and neither array can push the stack past `2n`.
fn writeCostRow(out: *std.Io.Writer, gpa: Allocator, name: []const u8, items: []const i32) !void {
    var storage: [64]?usize = undefined;
    const answers = storage[0..items.len];

    var comparisons: usize = 0;
    scanRight(items, answers, &comparisons);

    var work: Work = .{};
    try nextGreater(gpa, items, answers, &work);

    try out.print("  {s: <12}", .{name});
    try out.print("{d:>3}{d:>7}{d:>8}{d:>6}\n", .{
        items.len,
        comparisons,
        work.pushes,
        work.pops,
    });
}

/// An answers table: the value at each index and where its answer lives.
fn writeAnswers(
    out: *std.Io.Writer,
    items: []const i32,
    answers: []const ?usize,
    heading: []const u8,
) !void {
    try out.print("  idx  val  {s}   at\n", .{heading});
    for (items, 0..) |value, i| {
        try writeCell(out, @intCast(i), 5);
        try writeCell(out, value, 5);
        const at = answers[i];
        try writeMaybe(out, if (at) |a| items[a] else null, 14);
        try writeMaybe(out, if (at) |a| @as(i32, @intCast(a)) else null, 5);
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;
    const gpa = init.gpa;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);

    try out.print("{d} values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // The pass, printed. Every pop resolves an index, and the stack is
    // decreasing on every row.
    try out.writeAll("next greater to the right, one pass with a stack\n");
    try traceNextGreater(out, gpa, values);

    var stack_answers: [64]?usize = undefined;
    var scan_answers: [64]?usize = undefined;
    var work: Work = .{};
    try nextGreater(gpa, values, stack_answers[0..values.len], &work);
    try out.print(
        "  {d} pushes, {d} pops over {d} values, ceiling 2n = {d}\n\n",
        .{ work.pushes, work.pops, values.len, 2 * values.len },
    );

    // The answers, and the scan they have to agree with.
    var comparisons: usize = 0;
    scanRight(values, scan_answers[0..values.len], &comparisons);
    try out.writeAll("the answers, and the scan they have to agree with\n");
    try writeAnswers(out, values, stack_answers[0..values.len], "next greater");
    try out.print(
        "  stack and scan agree -> {}\n\n",
        .{std.mem.eql(?usize, stack_answers[0..values.len], scan_answers[0..values.len])},
    );

    // The rates, not the totals. Eleven values is too few for the scan to look
    // bad, so the two arrays that bracket it are here too.
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n  scans  pushes  pops\n");
    try writeCostRow(out, gpa, "the input", values);
    try writeCostRow(out, gpa, "decreasing", &decreasing);
    try writeCostRow(out, gpa, "increasing", &increasing);
    try out.writeAll("\n");

    // The same stack, one comparison flipped and the answer read from the
    // survivor instead of the values popped.
    try out.writeAll("previous smaller to the left, from the same stack\n");
    var left_answers: [64]?usize = undefined;
    var left_work: Work = .{};
    try previousSmaller(gpa, values, left_answers[0..values.len], &left_work);
    try writeAnswers(out, values, left_answers[0..values.len], "prev smaller");
    try out.print(
        "  {d} pushes, {d} pops, same ceiling\n",
        .{ left_work.pushes, left_work.pops },
    );

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.monotonic-stack`)*

## Scanning right from every index

<SnippetSource name="23-competitive.monotonic-stack" decl="scanRight" />

The direct solution is easy to understand.

For each index, scan to the right until a larger value is found.

If one is found, store it.

If the end of the array is reached, there is no answer for that index.

This solution is correct.

The problem is the number of comparisons.

The cost depends on the input.

For an increasing array:

`1 2 3 4 5`

each value except the last finds its answer immediately.

So each index needs only one comparison.

For a decreasing array:

`9 8 7 6 5`

no value ever finds a larger value to its right.

The first index checks four values.

The second checks three.

Then two.

Then one.

The total is:

`n(n - 1) / 2`

So the worst-case time complexity is O(n²).

## The stack stores indices still waiting for an answer

<SnippetSource name="23-competitive.monotonic-stack" decl="nextGreater" />

The monotonic-stack solution looks at the problem from the other direction.

When we reach index `i`, we do not immediately try to find the answer for `i`.

Instead, the current value may answer some earlier indices.

The stack contains indices whose next greater value has not been found yet.

Suppose the current value is:

`items[i]`

Look at the index on top of the stack.

If:

`items[i] > items[stack_top]`

then the current value is the next greater value for that stored index.

So we pop that index and record the answer.

Then we check the next index on the stack.

We continue until the stack is empty or the value on top is greater than or equal to the current value.

After that, we push `i`.

The values represented by the stack stay in decreasing order from bottom to top.

For example, if the stack contains values:

`9 7 5 3`

then a new value of 6 can answer 3 and 5.

It cannot answer 7.

So the popping stops there.

This ordering happens naturally.

Before pushing a new value, every smaller value at the top has already been removed.

The new value is then pushed above values that are greater than or equal to it.

The comparison must treat equal values correctly.

An equal value is not a greater value.

If an index is waiting for something greater than 5, another 5 does not answer it.

`out` starts filled with null values.

An answer is written only when an index is popped from the stack.

If an index is still on the stack when the loop finishes, there was no larger value to its right.

Its output remains null.

The stack is implemented with `std.ArrayList(usize)` and used from one end.

[Stacks](https://www.ziglang.in/learn/standard-library/stacks/) covers `append`, `pop` and `last`, and [Growable Array](https://www.ziglang.in/learn/data-structures/growable-array/) covers how the underlying storage grows.

If the maximum size is known, the same algorithm could use a fixed array and a length counter instead.

## Following the stack

<SnippetSource name="23-competitive.monotonic-stack" decl="traceNextGreater" />

Each row shows one incoming value.

The `resolved` column shows which earlier indices received an answer.

The final column shows the stack after processing the current value.

Each stack entry is written as:

`index:value`

from bottom to top.

```
   i  val  resolved (index -> answer)   stack after (bottom to top)
   0    3  .                           0:3
   1    1  .                           0:3 1:1
   2    4  1 -> 4, 0 -> 4              2:4
   3    1  .                           2:4 3:1
   4    5  3 -> 5, 2 -> 5              4:5
   5    9  4 -> 9                      5:9
   6    2  .                           5:9 6:2
   7    6  6 -> 6                      5:9 7:6
   8    5  .                           5:9 7:6 8:5
   9    3  .                           5:9 7:6 8:5 9:3
  10    7  9 -> 7, 8 -> 7, 7 -> 7      5:9 10:7
  2 indices never popped: 5:9 10:7
```

At index 0, the value is 3.

There is nothing waiting, so index 0 is pushed.

At index 1, the value is 1.

It is not larger than 3, so nothing is resolved.

Index 1 is pushed above index 0.

At index 2, the value is 4.

4 is larger than 1, so index 1 is popped and its answer becomes 4.

4 is also larger than 3, so index 0 is popped and its answer also becomes 4.

The stack is now empty.

Index 2 is pushed.

Later, at index 10, the value is 7.

It resolves indices 9, 8 and 7.

Then it reaches index 5, whose value is 9.

7 is not larger than 9, so the popping stops.

At the end, two indices remain:

`5:9`

and:

`10:7`

Neither has a larger value to its right.

So their answers remain null.

The program compares the stack solution with the direct scanning solution:

```
  stack and scan agree -> true
```

## Why the nested loop is still O(n)

<SnippetSource name="23-competitive.monotonic-stack" decl="writeCostRow" />

The algorithm contains a `while` loop inside a `for` loop.

At first this can look like O(n²).

It is not.

The important question is how many times an index can enter and leave the stack.

Each index is pushed exactly once.

So there are exactly `n` pushes.

An index can also be popped at most once.

Once it is popped, it is never added again.

So there can be at most `n` pops.

That gives at most about `2n` stack operations across the entire function.

For this example:

```
  11 pushes, 9 pops over 11 values, ceiling 2n = 22
```

The inner loop may run several times during one outer-loop iteration.

But those pops cannot happen again later.

This is why the total work stays linear.

The example compares both approaches on different inputs:

```
  array         n  scans  pushes  pops
  the input    11     19      11     9
  decreasing    9     36       9     0
  increasing    9      8       9     8
```

For the decreasing array, the direct scan performs 36 comparisons.

The monotonic stack performs nine pushes and no pops.

For the increasing array, the direct scan performs only eight comparisons.

The stack performs nine pushes and eight pops.

So the stack is not always faster on every individual input.

Its advantage is the worst-case bound.

The direct scan can grow to O(n²).

The monotonic stack stays O(n) for every input.

A nested loop does not automatically mean quadratic time.

If every item can enter the inner loop only a fixed number of times across the whole algorithm, the total work can still be linear.

## Previous smaller element

<SnippetSource name="23-competitive.monotonic-stack" decl="previousSmaller" />

The same idea can solve another common problem:

For each value, find the nearest smaller value to its left.

The structure is almost the same.

The comparison changes, and we read the answer from the index that remains on the stack after larger or equal values have been removed.

For example:

```
  idx  val  prev smaller   at
    0    3             .    .
    1    1             .    .
    2    4             1    1
    3    1             .    .
    4    5             1    3
    5    9             5    4
    6    2             1    3
```

Consider index 6, whose value is 2.

The stack may contain values 5 and 9 above an earlier 1.

Both 5 and 9 are too large to be the previous smaller value for 2.

So they are popped.

The next value is 1 at index 3.

That value is smaller than 2, so index 3 is the answer.

The popped indices are no longer useful for future values.

The current 2 is closer to future positions and is smaller than both of them.

So any future value that could use 5 or 9 as a previous smaller value could use 2 instead.

Rows 1 and 3 have no previous smaller value.

Both contain 1, which is the smallest value seen up to those positions.

The stack becomes empty before their answer is read.

The number of stack operations is still linear:

```
  11 pushes, 7 pops, same ceiling
```

This gives us a common family of monotonic-stack problems:

- next greater element
- next smaller element
- previous greater element
- previous smaller element

The same basic structure works for all four.

What changes is:

- whether we scan from left to right or right to left
- whether the stack is increasing or decreasing
- whether we pop on greater or smaller values
- whether the answer comes from the current value or from the stack after popping

The main idea stays the same: keep only the indices that can still be useful later.
