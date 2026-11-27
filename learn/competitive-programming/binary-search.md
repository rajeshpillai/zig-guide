# Binary Search

> The half-open window, the invariant that keeps the window correct, and the two bounds that std already has.

Binary search is a small loop, but some details must be correct. One common mistake gives the wrong index. A different mistake makes the loop run forever.

Both versions compile. Thus you must know exactly what each variable means.

The program below prints each step of the search. Each line shows `lo`, `hi`, `mid`, the value at `mid`, and the part of the array that the search did not remove.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. A contest problem gives you a line of sorted values and a line of
/// queries. This constant holds the same two lines. The parser below reads
/// the constant in the same way that it reads a real file.
const input =
    \\1 3 3 4 7 7 7 9 11 11 15 20
    \\7 5 20 0 21
;

/// Read one line of whitespace-separated integers into `out`.
///
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. The function changes
/// bytes into values. Thus the same code works with a file, a socket, or a
/// string literal that CI can check.
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

/// The first index with a value that is not less than `key`.
///
/// The window is half-open: each index that can be the answer is in
/// `items[lo..hi]`. `lo` moves only past values that are too small. `hi`
/// moves down only to values that are sufficiently large. Thus the answer
/// always stays in the window. When `lo` gets to `hi`, the window is empty
/// and `lo` is the answer. For this reason, the function has no separate case
/// for a value that it cannot find.
///
/// Use `lo + (hi - lo) / 2`, not `(lo + hi) / 2`. The second form adds two
/// indices. Each index is valid, but on a large array the sum can be too
/// large.
fn lowerBound(items: []const i32, key: i32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The first index with a value that is greater than `key`.
///
/// The only difference from `lowerBound` is one character. With `<=`, the
/// loop moves past each value that is equal to the key. It does not stop at
/// the first equal value.
fn upperBound(items: []const i32, key: i32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the table is easy to read.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// One line of the trace: the counters, then the array. The line shows the
/// current window, and the middle value is in brackets.
///
/// A value outside `items[lo..hi]` prints as a dot. Thus you can see the window
/// become half as large. You do not have to calculate it from three numbers.
fn writeStep(
    out: *std.Io.Writer,
    items: []const i32,
    step: usize,
    lo: usize,
    mid: usize,
    hi: usize,
) !void {
    try out.print("  step {d}  lo={d:>2} mid={d:>2} hi={d:>2} ", .{ step, lo, mid, hi });
    for (items, 0..) |value, i| {
        if (i < lo or i >= hi) {
            try out.writeAll("   .");
        } else if (i == mid) {
            try out.writeByte('[');
            try writeCell(out, value, 2);
            try out.writeByte(']');
        } else {
            try writeCell(out, value, 4);
        }
    }
    try out.writeByte('\n');
}

/// The same search as `lowerBound`, but it prints the window at each step.
///
/// This function is separate, thus `lowerBound` keeps the shape that you can
/// copy into a solution. The run below checks that the two functions return
/// the same index. It does not assume that they do.
fn traceLowerBound(out: *std.Io.Writer, items: []const i32, key: i32) !usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    var step: usize = 0;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        step += 1;
        try writeStep(out, items, step, lo, mid, hi);
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    try out.print("  window empty after {d} steps: lo = hi = {d}\n", .{ step, lo });
    return lo;
}

/// The off-by-one bug, as a program that you can run.
///
/// `lo = mid` looks safe next to `lo = mid + 1`. `mid` was too small, thus
/// it looks like `mid` in the window costs only one more comparison. But
/// `lo = mid` stops the loop. When `hi - lo` is 1, `mid` is `lo`. Then
/// `lo = mid` does not change the window, and the next step is the same as
/// this step.
///
/// The step limit lets the program print the problem. Without the limit, the
/// loop does not stop.
fn stalledLowerBound(
    out: *std.Io.Writer,
    items: []const i32,
    key: i32,
    budget: usize,
) !?usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    var step: usize = 0;
    while (lo < hi) {
        if (step == budget) {
            try out.print("  no progress: gave up at step {d} with lo={d} hi={d}\n", .{ step, lo, hi });
            return null;
        }
        const mid = lo + (hi - lo) / 2;
        step += 1;
        try writeStep(out, items, step, lo, mid, hi);
        if (items[mid] < key) lo = mid else hi = mid;
    }
    return lo;
}

/// The comparator that `std.sort` needs: the key first, the element second.
///
/// Compare the order of the arguments with the source of `std.sort`. A
/// comparator with the arguments in the opposite order compiles. Then it
/// returns an index that looks correct but is wrong.
fn orderKeyFirst(key: i32, item: i32) std.math.Order {
    return std.math.order(key, item);
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    var query_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);
    const queries = try readRow(&reader, &query_storage);

    try out.print("{d} sorted values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // The search with a trace, and the search without a trace. The two must
    // give the same answer.
    try out.writeAll("lower bound of 7, the first index whose value is not less than 7\n");
    const traced = try traceLowerBound(out, values, 7);
    try out.print(
        "  traced {d}, plain lowerBound {d}, same answer -> {}\n\n",
        .{ traced, lowerBound(values, 7), traced == lowerBound(values, 7) },
    );

    // Two bounds change a search into a range. A contest problem usually
    // asks for this: how many, not where.
    const first = lowerBound(values, 7);
    const past = upperBound(values, 7);
    try out.print("upper bound of 7 is {d}\n", .{past});
    try out.print("7 occupies items[{d}..{d}], which is {d} copies\n\n", .{ first, past, past - first });

    try out.writeAll("every query, answered with the same two calls\n");
    try out.writeAll("  key  lower  upper  count  present\n");
    for (queries) |key| {
        const lo = lowerBound(values, key);
        const hi = upperBound(values, key);
        try writeCell(out, key, 5);
        try out.print(
            "  {d:>5}  {d:>5}  {d:>5}  {s}\n",
            .{ lo, hi, hi - lo, if (hi > lo) "yes" else "no" },
        );
    }
    try out.writeAll("\n");

    // The window must become smaller at each step. This search shows the
    // result when the window stops at one size.
    try out.writeAll("the same search with lo = mid instead of lo = mid + 1\n");
    const stalled = try stalledLowerBound(out, values, 7, 6);
    try out.print("  answer -> {?d}\n\n", .{stalled});

    // The standard library has the two bounds. Thus a solution does not need
    // the code above. This file has the code because the index from a bound
    // is useful only when you know which bound you used.
    try out.writeAll("std.sort, on the same array\n");
    try out.print(
        "  std.sort.lowerBound(7) = {d}, ours = {d}\n",
        .{ std.sort.lowerBound(i32, values, @as(i32, 7), orderKeyFirst), lowerBound(values, 7) },
    );
    try out.print(
        "  std.sort.upperBound(7) = {d}, ours = {d}\n",
        .{ std.sort.upperBound(i32, values, @as(i32, 7), orderKeyFirst), upperBound(values, 7) },
    );
    try out.print(
        "  std.sort.equalRange(7) = {any}\n",
        .{std.sort.equalRange(i32, values, @as(i32, 7), orderKeyFirst)},
    );
    try out.print(
        "  std.sort.binarySearch(5) = {?d}, lowerBound(5) = {d}\n",
        .{ std.sort.binarySearch(i32, values, @as(i32, 5), orderKeyFirst), lowerBound(values, 5) },
    );

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.binary-search`)*

## The search window

```zig
/// The first index with a value that is not less than `key`.
///
/// The window is half-open: each index that can be the answer is in
/// `items[lo..hi]`. `lo` moves only past values that are too small. `hi`
/// moves down only to values that are sufficiently large. Thus the answer
/// always stays in the window. When `lo` gets to `hi`, the window is empty
/// and `lo` is the answer. For this reason, the function has no separate case
/// for a value that it cannot find.
///
/// Use `lo + (hi - lo) / 2`, not `(lo + hi) / 2`. The second form adds two
/// indices. Each index is valid, but on a large array the sum can be too
/// large.
fn lowerBound(items: []const i32, key: i32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}
```

*Quoted from the source: `lowerBound` from `snippets/23-competitive/binary-search.zig`.*

`lo` and `hi` give the part of the array that the search did not remove. This part is the search window.

The range is half-open, `items[lo..hi]`. The window includes `lo`, but it does not include `hi`.

At each step, the loop keeps one rule: each index that can be the answer stays inside the search window.

The loop has two branches:

- If `items[mid] < key`, then `mid` cannot be the answer. The values are in ascending order, thus each value before `mid` is also too small. The loop sets `lo = mid + 1`. This removes `mid` and all of the values before `mid`.
- If not, `items[mid]` is greater than or equal to the key. Then `mid` can be the answer. The loop keeps `mid` inside the search window with `hi = mid`.

Thus one branch moves past `mid`, and the other branch keeps `mid` in the window.

When `lo == hi`, the search window is empty and the search is complete. Then `lo` is the lower-bound position. The function does not have a separate case for a value that it cannot find.

```
  step 1  lo= 0 mid= 6 hi=12    1   3   3   4   7   7[ 7]   9  11  11  15  20
  step 2  lo= 0 mid= 3 hi= 6    1   3   3[ 4]   7   7   .   .   .   .   .   .
  step 3  lo= 4 mid= 5 hi= 6    .   .   .   .   7[ 7]   .   .   .   .   .   .
  step 4  lo= 4 mid= 4 hi= 5    .   .   .   .[ 7]   .   .   .   .   .   .   .
  window empty after 4 steps: lo = hi = 4
```

The array has twelve values, and the search stops after four steps. A dot shows an index that the search removed. Each step removes approximately half of the range that is still in the window.

The figure below plays the same four rows. Use **Next step** to move one state at a time. The highlighted line is the line of `lowerBound` that runs. At step 2, the figure stops and asks you to predict the branch.

*Figure: Binary search for the lower bound of 7 in twelve sorted values, with lo, mid and hi pointers and the lowerBound source. The trace of lowerBound(7) from the program above. Each step shows mid, the branch, and the window that is left.*

The program calculates the midpoint as `lo + (hi - lo) / 2`. You can also see `(lo + hi) / 2` in other code. The second form is shorter, but `lo + hi` can overflow if the two values are sufficiently large. The first form does not have this problem.

The overflow is more probable with small integer types and very large arrays. `lo + (hi - lo) / 2` is the safer form, and the cost is only one subtraction.

## The off-by-one bug

```zig
/// The off-by-one bug, as a program that you can run.
///
/// `lo = mid` looks safe next to `lo = mid + 1`. `mid` was too small, thus
/// it looks like `mid` in the window costs only one more comparison. But
/// `lo = mid` stops the loop. When `hi - lo` is 1, `mid` is `lo`. Then
/// `lo = mid` does not change the window, and the next step is the same as
/// this step.
///
/// The step limit lets the program print the problem. Without the limit, the
/// loop does not stop.
fn stalledLowerBound(
    out: *std.Io.Writer,
    items: []const i32,
    key: i32,
    budget: usize,
) !?usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    var step: usize = 0;
    while (lo < hi) {
        if (step == budget) {
            try out.print("  no progress: gave up at step {d} with lo={d} hi={d}\n", .{ step, lo, hi });
            return null;
        }
        const mid = lo + (hi - lo) / 2;
        step += 1;
        try writeStep(out, items, step, lo, mid, hi);
        if (items[mid] < key) lo = mid else hi = mid;
    }
    return lo;
}
```

*Quoted from the source: `stalledLowerBound` from `snippets/23-competitive/binary-search.zig`.*

A common mistake is to write `lo = mid` instead of `lo = mid + 1`.

At first, `lo = mid` can look correct. If `mid` is too small, the answer is not before `mid`. But `mid` also cannot be the answer. Thus the loop must remove `mid` from the search window.

If the loop keeps `mid`, the loop can stop progress. When `hi - lo` becomes 1, integer division gives `mid == lo`. Then `lo = mid` does not change a value. The next iteration gets the same values again.

```
  step 3  lo= 3 mid= 4 hi= 6    .   .   .   4[ 7]   7   .   .   .   .   .   .
  step 4  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  step 5  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  step 6  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  no progress: gave up at step 6 with lo=3 hi=4
```

Steps four, five and six are the same. The example has a step limit, thus the program can find the problem and stop. Without the limit, the loop does not stop. On a competitive programming judge, the result is usually a time-limit error.

The next figure runs both versions on the same array. Select a branch, and step through the search. The steps have the same names in the two versions, thus you can change the branch at any step. Up to step 2, the two windows are the same. At step 3, `lo = mid` keeps index 3, and the window stops at two values.

*Figure: The same binary search twice: with lo = mid + 1 it ends after four steps, and with lo = mid it repeats one window. Select a branch. The steps have the same names in both, thus you can switch at any step and compare the two windows.*

A simple rule helps you find this bug: the search window must become smaller after each iteration. In this implementation, each branch makes the window smaller by one index or more.

## lowerBound and upperBound

```zig
/// The first index with a value that is greater than `key`.
///
/// The only difference from `lowerBound` is one character. With `<=`, the
/// loop moves past each value that is equal to the key. It does not stop at
/// the first equal value.
fn upperBound(items: []const i32, key: i32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}
```

*Quoted from the source: `upperBound` from `snippets/23-competitive/binary-search.zig`.*

`lowerBound` and `upperBound` are almost the same search. The only difference is the comparison.

`lowerBound` uses `<`. It finds the first position with a value that is greater than or equal to the key:

```
first value >= key
```

`upperBound` uses `<=`. It finds the first position with a value that is greater than the key:

```
first value > key
```

If the key occurs more than one time, `lowerBound` points to the first copy. `upperBound` points to the position immediately after the last copy.

The two bounds make a half-open range:

```
[lowerBound, upperBound)
```

Thus the count of duplicates is easy to calculate:

```
count = upperBound - lowerBound
```

The results for the example array are:

```
  key  lower  upper  count  present
    7      4      7      3  yes
    5      4      4      0  no
   20     11     12      1  yes
    0      0      0      0  no
   21     12     12      0  no
```

For key `7`, the range is:

```
[4, 7)
```

Thus the array has three copies of `7`.

For key `5`, the two bounds are 4. Thus the array does not contain `5`. Position 4 is also the position where an insert of `5` keeps the array sorted.

For key `21`, the two bounds are 12, which is the end of the array. Thus an insert of `21` goes after all of the values.

`lowerBound` is also useful when the array does not contain the value:

- It gives the first position where you can insert the value.
- It gives the count of values that are smaller than a given limit.

## Use the Zig standard library

`std.sort` already has these operations: `lowerBound`, `upperBound`, `equalRange` and `binarySearch`. In usual code, you do not have to write the binary-search loop.

You must supply a comparator. Be careful with one detail: the comparator gets the key first and the array element second.

```zig
/// The comparator that `std.sort` needs: the key first, the element second.
///
/// Compare the order of the arguments with the source of `std.sort`. A
/// comparator with the arguments in the opposite order compiles. Then it
/// returns an index that looks correct but is wrong.
fn orderKeyFirst(key: i32, item: i32) std.math.Order {
    return std.math.order(key, item);
}
```

*Quoted from the source: `orderKeyFirst` from `snippets/23-competitive/binary-search.zig`.*

The order of the arguments is important. If the two arguments have the same type, the wrong order can still compile. But then the comparison has a different meaning, and the result can be wrong.

The results for the array in this example are:

```
  std.sort.lowerBound(7) = 4, ours = 4
  std.sort.upperBound(7) = 7, ours = 7
  std.sort.equalRange(7) = .{ 4, 7 }
  std.sort.binarySearch(5) = null, lowerBound(5) = 4
```

`std.sort.binarySearch` returns `?usize`:

- If the value is in the array, the function returns an index of the value.
- If the value is not in the array, the function returns null.

When the array has duplicates, `binarySearch` does not guarantee the first index of the value. Use `lowerBound` when you need the first position of the value.

The last line shows the difference between `binarySearch` and `lowerBound`. For key `5`, `binarySearch` returns null, because the array does not contain `5`:

```
binarySearch(5) = null
```

But `lowerBound` returns 4, which is the position where an insert of `5` goes:

```
lowerBound(5) = 4
```

All of these functions expect sorted input. `std.sort` does not check the order for you.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) tells about `std.mem.sort`, the stable and unstable variants, and the context argument that these comparators also use.

## Read the example input

```zig
/// Read one line of whitespace-separated integers into `out`.
///
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. The function changes
/// bytes into values. Thus the same code works with a file, a socket, or a
/// string literal that CI can check.
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
```

*Quoted from the source: `readRow` from `snippets/23-competitive/binary-search.zig`.*

The examples on this site run under WASI in the browser. A program in the browser does not have standard input in the same way as a usual command-line program. Thus the source file keeps the example input as a string.

`readRow` does not use the string directly. It accepts a `*std.Io.Reader`. Thus the same function can parse input from different sources: a string, a file, a socket or standard input. On a competitive programming judge, you can give the same function a reader on stdin.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/) tells about the interface and the buffer that it reads through.
