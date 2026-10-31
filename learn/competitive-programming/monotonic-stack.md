# The Monotonic Stack

> A stack of the indices that still wait for an answer, and the two counters that show the inner loop keeps the total linear.

The problem: for each value in an array, find the first larger value to its right. Some values find a larger value immediately. Some values must look much farther. Some values do not have a larger value to their right.

A simple solution starts at each index and scans to the right until it finds a larger value. That solution works, but in the worst case it checks almost each pair of values.

A monotonic stack solves the same problem in one pass. The question changes. The question is not "What is the answer for this index?". The question is "Which earlier indices can the current value answer?". The stack keeps the indices that still wait for a larger value.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The problem needs only one line of values. The parser below reads
/// the line in the same way that it reads a real file.
const input =
    \\3 1 4 1 5 9 2 6 5 3 7
;

/// The worst array for a scan and the easiest array for the stack.
///
/// No value has a greater value to its right. Thus the scan goes to the end
/// from each index, and the stack never pops.
const decreasing = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The opposite of `decreasing`. The scan stops at its first comparison each
/// time. The stack pops the index that it pushed on the step before.
const increasing = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

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

/// The two counters that the amortised argument uses.
///
/// The count costs two lines. It answers a question that is easy to get wrong
/// if you only think about the nested loop.
const Work = struct {
    pushes: usize = 0,
    pops: usize = 0,
};

/// For each index, the index of the first greater value to its right.
///
/// The direct solution. Select an index, then move right to a greater value,
/// or stop at the end of the array. `comparisons` counts the values that the
/// scan examines. This number increases with the square of the input size.
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
/// The stack holds the indices that do not have an answer yet. The values of
/// these indices become smaller from bottom to top. When `value` comes, each
/// index on the stack with a smaller value has its answer. Because of the
/// order, these indices are together at the top. Pop them, record `i`, and
/// push `i`.
///
/// The loop itself keeps the order. Each index that stays after the pops has
/// a value that is equal to or larger than `value`. Thus with `i` on top, the
/// values on the stack still become smaller from bottom to top.
///
/// Use `>=`, not `>`. An equal value is not greater. Thus a second 7 does not
/// answer an index that waits for a value greater than 7.
///
/// The loop never writes the indices that are still on the stack at the end
/// of the array. Before the loop, `@memset` set each item in `out` to null.
/// Thus an index without an answer does not need a separate case.
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

/// The first smaller value to the left, from the same method.
///
/// There are two changes. First, the comparison is the opposite. Thus the
/// values on the stack become larger from bottom to top. Second, the answer
/// comes from the index that stays on the stack, not from the popped indices.
/// After the pops, the index on top is the nearest index to the left with a
/// smaller value.
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
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the columns are easy to read.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// A value that can be absent, right-aligned. A dot means no answer.
fn writeMaybe(out: *std.Io.Writer, value: ?i32, width: usize) !void {
    if (value) |v| return writeCell(out, v, width);
    try out.splatByteAll(' ', width - 1);
    try out.writeByte('.');
}

/// The stack, bottom to top, as `index:value` pairs.
///
/// The values next to the indices show the order. A column of only indices
/// hides the property that the method needs.
fn writeStack(out: *std.Io.Writer, items: []const i32, indices: []const usize) !void {
    for (indices, 0..) |idx, k| {
        if (k > 0) try out.writeByte(' ');
        try out.print("{d}:{d}", .{ idx, items[idx] });
    }
}

/// The indices that this step resolved, each with its answer.
///
/// All these indices get the same answer, because the same new value popped
/// them. The row shows the answer for each index. Thus the row is easy to
/// compare with the answers table below.
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

/// `nextGreater`, but it prints a row for each new value.
///
/// This function is separate, thus `nextGreater` keeps the shape that you can
/// copy into a solution. The run below checks that the two functions agree. It
/// does not assume that they do. The last row also shows the result at the
/// end: each index on the stack at that time never found a greater value.
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

/// One row of the cost table: the cost of the scan and the cost of the stack.
///
/// The two methods use the same array. Thus you can compare the two numbers,
/// because they do not come from different runs. The count for the scan is
/// comparisons, and the count for the stack is moves. No array can make the
/// stack moves more than `2n`.
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

/// An answers table: the value at each index and the position of its answer.
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

    // The pass, with a trace. Each pop resolves an index. On each row, the
    // values on the stack become smaller from bottom to top.
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

    // The answers, and the scan that they must agree with.
    var comparisons: usize = 0;
    scanRight(values, scan_answers[0..values.len], &comparisons);
    try out.writeAll("the answers, and the scan they have to agree with\n");
    try writeAnswers(out, values, stack_answers[0..values.len], "next greater");
    try out.print(
        "  stack and scan agree -> {}\n\n",
        .{std.mem.eql(?usize, stack_answers[0..values.len], scan_answers[0..values.len])},
    );

    // The rates, not the totals. Eleven values are not sufficient to show the
    // cost of the scan. Thus the program also uses the two arrays at the two
    // limits.
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n  scans  pushes  pops\n");
    try writeCostRow(out, gpa, "the input", values);
    try writeCostRow(out, gpa, "decreasing", &decreasing);
    try writeCostRow(out, gpa, "increasing", &increasing);
    try out.writeAll("\n");

    // The same stack with the opposite comparison. The answer comes from the
    // index that stays on the stack, not from the popped indices.
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

## Scan right from each index

```zig
/// For each index, the index of the first greater value to its right.
///
/// The direct solution. Select an index, then move right to a greater value,
/// or stop at the end of the array. `comparisons` counts the values that the
/// scan examines. This number increases with the square of the input size.
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
```

*Quoted from the source: `scanRight` from `snippets/23-competitive/monotonic-stack.zig`.*

The direct solution is easy to understand. For each index, scan to the right until you find a larger value:

- If you find a larger value, store it.
- If you get to the end of the array, that index has no answer.

This solution is correct. The problem is the number of comparisons, and the number changes with the input.

For an array in ascending order such as `1 2 3 4 5`, each value except the last value finds its answer immediately. Thus each of these indices needs only one comparison.

For an array in descending order such as `9 8 7 6 5`, no value finds a larger value to its right. The first index checks four values, the second index checks three, then two, then one. The total is `n(n - 1) / 2` comparisons. Thus the worst-case time complexity is O(n²).

## The stack keeps the indices that wait for an answer

```zig
/// The same answers from one pass over the array.
///
/// The stack holds the indices that do not have an answer yet. The values of
/// these indices become smaller from bottom to top. When `value` comes, each
/// index on the stack with a smaller value has its answer. Because of the
/// order, these indices are together at the top. Pop them, record `i`, and
/// push `i`.
///
/// The loop itself keeps the order. Each index that stays after the pops has
/// a value that is equal to or larger than `value`. Thus with `i` on top, the
/// values on the stack still become smaller from bottom to top.
///
/// Use `>=`, not `>`. An equal value is not greater. Thus a second 7 does not
/// answer an index that waits for a value greater than 7.
///
/// The loop never writes the indices that are still on the stack at the end
/// of the array. Before the loop, `@memset` set each item in `out` to null.
/// Thus an index without an answer does not need a separate case.
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
```

*Quoted from the source: `nextGreater` from `snippets/23-competitive/monotonic-stack.zig`.*

The monotonic-stack solution examines the problem from the other direction. At index `i`, the solution does not immediately try to find the answer for `i`. Instead, the current value can answer some earlier indices. The stack contains the indices that do not have their next greater value yet.

The current value is `items[i]`. For each value, do these steps:

1. Look at the index on the top of the stack.
2. If `items[i] > items[stack_top]`, the current value is the next greater value for that index. Pop that index and record the answer.
3. Do steps 1 and 2 again. Stop when the stack is empty or the top value is greater than or equal to the current value.
4. Push `i`.

The values of the indices on the stack become smaller from the bottom to the top. For example, if the stack contains the values `9 7 5 3`, a new value of 6 can answer 3 and 5. The value 6 cannot answer 7. Thus the pops stop at 7.

The stack keeps this order without more work. Before the push of a new value, the loop already removed each smaller value at the top. Then the loop pushes the new value above values that are greater than or equal to it.

The comparison must be correct for equal values. An equal value is not a greater value. If an index waits for a value greater than 5, a second 5 does not answer that index.

At the start, all the values in `out` are null. The loop writes an answer only when it pops an index from the stack. If an index is still on the stack at the end of the loop, there was no larger value to its right. Thus the output for that index stays null.

The stack is a `std.ArrayList(usize)`, and the code uses only one end of it. [Stacks](https://www.ziglang.in/learn/standard-library/stacks/) tells about `append`, `pop` and `last`. [Growable Array](https://www.ziglang.in/learn/data-structures/growable-array/) tells how the storage below the list grows.

If you know the maximum size, the same algorithm can use a fixed array and a length counter instead.

## Follow the stack

```zig
/// `nextGreater`, but it prints a row for each new value.
///
/// This function is separate, thus `nextGreater` keeps the shape that you can
/// copy into a solution. The run below checks that the two functions agree. It
/// does not assume that they do. The last row also shows the result at the
/// end: each index on the stack at that time never found a greater value.
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
```

*Quoted from the source: `traceNextGreater` from `snippets/23-competitive/monotonic-stack.zig`.*

Each row shows one new value:

- The `resolved` column shows the earlier indices that got an answer.
- The last column shows the stack after the step for the current value.
- Each stack entry has the form `index:value`, from the bottom to the top.

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

At index 0, the value is 3. No index waits, thus the loop pushes index 0.

At index 1, the value is 1. The value 1 is not larger than 3, thus no index gets an answer. The loop pushes index 1 above index 0.

At index 2, the value is 4. The value 4 is larger than 1, thus the loop pops index 1, and its answer becomes 4. The value 4 is also larger than 3, thus the loop pops index 0, and its answer also becomes 4. The stack is now empty. The loop pushes index 2.

Later, at index 10, the value is 7. The value 7 answers indices 9, 8 and 7. Then the loop gets to index 5, which has the value 9. The value 7 is not larger than 9, thus the pops stop.

At the end, two indices stay on the stack: `5:9` and `10:7`. These two indices do not have a larger value to their right. Thus their answers stay null.

The figure plays the same trace. Each step moves `i` to the next value, pops the entries that the value answers, and pushes the new index. At index 2 and at index 10, the figure stops. Predict the pops, then press **Reveal**.

*Figure: Eleven input values scanned left to right. Each value pops the smaller values from a stack and writes their next greater value. The trace from the program above, one index for each step. Two steps stop and ask you to predict the pops.*

The program compares the stack solution with the direct scan:

```
  stack and scan agree -> true
```

## Why the nested loop is still O(n)

```zig
/// One row of the cost table: the cost of the scan and the cost of the stack.
///
/// The two methods use the same array. Thus you can compare the two numbers,
/// because they do not come from different runs. The count for the scan is
/// comparisons, and the count for the stack is moves. No array can make the
/// stack moves more than `2n`.
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
```

*Quoted from the source: `writeCostRow` from `snippets/23-competitive/monotonic-stack.zig`.*

The algorithm has a `while` loop inside a `for` loop. At first, this can look like O(n²), but it is O(n). To see why, count how many times an index can go onto the stack and come off the stack.

- The loop pushes each index exactly one time. Thus there are exactly `n` pushes.
- The loop can pop an index a maximum of one time. After the pop, the loop never adds that index again. Thus there can be a maximum of `n` pops.

Thus the full function has a maximum of approximately `2n` stack operations. The counts for this example are:

```
  11 pushes, 9 pops over 11 values, ceiling 2n = 22
```

The inner loop can run many times in one iteration of the outer loop. But these pops cannot occur again later. Thus the total work for the full array stays linear.

The example compares the two methods on different inputs:

```
  array         n  scans  pushes  pops
  the input    11     19      11     9
  decreasing    9     36       9     0
  increasing    9      8       9     8
```

For the `decreasing` array, the direct scan does 36 comparisons. The monotonic stack does nine pushes and no pops.

For the `increasing` array, the direct scan does only eight comparisons. The stack does nine pushes and eight pops.

Thus the stack is not always faster on each input. Its advantage is the worst-case bound. The direct scan can increase to O(n²). The monotonic stack stays O(n) for all inputs.

A nested loop does not always mean quadratic time. Count how many times each item can go into the inner loop in the full algorithm. If that count has a constant limit, the total work can still be linear.

## Previous smaller element

```zig
/// The first smaller value to the left, from the same method.
///
/// There are two changes. First, the comparison is the opposite. Thus the
/// values on the stack become larger from bottom to top. Second, the answer
/// comes from the index that stays on the stack, not from the popped indices.
/// After the pops, the index on top is the nearest index to the left with a
/// smaller value.
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
```

*Quoted from the source: `previousSmaller` from `snippets/23-competitive/monotonic-stack.zig`.*

The same method solves a different common problem: for each value, find the nearest smaller value to its left. The structure is almost the same, with two changes:

- The comparison is different.
- The answer comes from the index that stays on the stack after the loop removes the larger or equal values.

The program prints:

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

Look at index 6, which has the value 2. At that step, the stack contains the values 5 and 9 above an earlier 1. The values 5 and 9 are too large to be the previous smaller value for 2. Thus the loop pops them. The next value is 1 at index 3. That value is smaller than 2, thus index 3 is the answer.

The popped indices are not useful for future values. The current 2 is nearer to future positions, and it is smaller than both of the popped values. Thus a future value that can use 5 or 9 as a previous smaller value can use 2 instead.

Rows 1 and 3 have no previous smaller value. These two rows contain 1, which is the smallest value up to those positions. The stack becomes empty before the loop reads their answer.

The number of stack operations is still linear:

```
  11 pushes, 7 pops, same ceiling
```

The method gives a common family of monotonic-stack problems:

- next greater element
- next smaller element
- previous greater element
- previous smaller element

The same basic structure works for all four. These items change:

- the direction of the scan: from left to right, or from right to left
- the order of the stack: values that become larger or smaller from the bottom to the top
- the condition for a pop: on greater values, or on smaller values
- the source of the answer: the current value, or the stack after the pops
