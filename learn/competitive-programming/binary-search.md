# Binary Search

> The half-open window, the invariant that keeps it correct, and the two bounds std already ships.

Binary search is a small loop, but a few details must be correct.

One common mistake gives the wrong index. Another mistake can make the loop run forever.

Both versions can compile correctly, so it is important to understand what each variable means.

The program below prints every step of the search. It shows `lo`, `hi`, `mid`, the value at `mid`, and the part of the array that is still being searched.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. A contest problem hands you a line of sorted values and a line of
/// queries, so that is what this holds, and the parser below reads it the way
/// it would read a real file.
const input =
    \\1 3 3 4 7 7 7 9 11 11 15 20
    \\7 5 20 0 21
;

/// Read one line of whitespace-separated integers into `out`.
///
/// Taking a `*std.Io.Reader` rather than the string is the same discipline the
/// networking chapters use for protocols. The function turns bytes into
/// values, so the same code works over a file, over a socket, and over a
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

/// First index whose value is not less than `key`.
///
/// The window is half-open: every index that could be the answer is in
/// `items[lo..hi]`. `lo` only moves past values that are too small and `hi`
/// only moves down to values that are large enough, so the answer never leaves
/// the window. When `lo` reaches `hi` the window holds nothing and `lo` is the
/// answer, which is why there is no separate not-found case.
///
/// `lo + (hi - lo) / 2` and not `(lo + hi) / 2`. The second one adds two
/// indices that are each valid on their own, and on a large array the sum is
/// not.
fn lowerBound(items: []const i32, key: i32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// First index whose value is greater than `key`.
///
/// One character apart from `lowerBound`: `<=` walks past every value equal to
/// the key instead of stopping at the first of them.
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
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the table readable.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// One line of the trace: the counters, then the array with the live window
/// drawn in and the middle value in brackets.
///
/// Values outside `items[lo..hi]` print as a dot. The window halving is then
/// something to watch rather than something to work out from three numbers.
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

/// The same walk as `lowerBound`, with the window printed at every step.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two return the same index rather
/// than trusting that they do.
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

/// The off-by-one, shown rather than described.
///
/// `lo = mid` reads as harmless next to `lo = mid + 1`. `mid` was too small,
/// so leaving it in the window looks like it only costs one comparison. It
/// costs the loop. Once `hi - lo` is 1, `mid` is `lo`, and `lo = mid` leaves
/// the window exactly as it was, so the next step is identical to this one.
///
/// The budget is what makes this printable. Without it the loop never ends.
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

/// The comparator `std.sort` wants: the key first, the element second.
///
/// The argument order is the part worth checking against the source. A
/// comparator written the other way round compiles and returns a plausible
/// wrong index.
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

    // The traced walk, and the untraced one it has to agree with.
    try out.writeAll("lower bound of 7, the first index whose value is not less than 7\n");
    const traced = try traceLowerBound(out, values, 7);
    try out.print(
        "  traced {d}, plain lowerBound {d}, same answer -> {}\n\n",
        .{ traced, lowerBound(values, 7), traced == lowerBound(values, 7) },
    );

    // Two bounds turn a search into a range, which is what a contest problem
    // usually wants: how many, not where.
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

    // The window has to shrink on every step. This is what it looks like when
    // it stops.
    try out.writeAll("the same search with lo = mid instead of lo = mid + 1\n");
    const stalled = try stalledLowerBound(out, values, 7, 6);
    try out.print("  answer -> {?d}\n\n", .{stalled});

    // The standard library ships both bounds, so none of the above needs
    // writing in a solution. It is written here because the index they return
    // is only useful once you know which one you asked for.
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

<SnippetSource name="23-competitive.binary-search" decl="lowerBound" />

`lo` and `hi` describe the part of the array that is still being searched.

The range is half-open:

`items[lo..hi]`

This means `lo` is included, but `hi` is not.

At every step, we maintain one important rule:

Every index that could still be the answer must remain inside the search window.

If:

`items[mid] < key`

then `mid` cannot be the answer.

Everything before `mid` is also too small because the array is sorted.

So we move:

`lo = mid + 1`

This removes `mid` and everything before it.

Otherwise, `items[mid]` is greater than or equal to the key.

`mid` may still be the answer, so we keep it inside the search window:

`hi = mid`

This difference between `mid + 1` and `mid` is important.

When `lo == hi`, the search window is empty and the search is complete.

At that point, `lo` is the lower-bound position.

There is no separate not-found case.

```
  step 1  lo= 0 mid= 6 hi=12    1   3   3   4   7   7[ 7]   9  11  11  15  20
  step 2  lo= 0 mid= 3 hi= 6    1   3   3[ 4]   7   7   .   .   .   .   .   .
  step 3  lo= 4 mid= 5 hi= 6    .   .   .   .   7[ 7]   .   .   .   .   .   .
  step 4  lo= 4 mid= 4 hi= 5    .   .   .   .[ 7]   .   .   .   .   .   .   .
  window empty after 4 steps: lo = hi = 4
```

The array contains twelve values, and the search finishes in four steps.

The dots show indices that have already been removed from consideration.

Each step removes roughly half of the remaining search range.

The midpoint is calculated as:

`lo + (hi - lo) / 2`

You may also see:

`(lo + hi) / 2`

The second version is shorter, but `lo + hi` can overflow if the two values are large enough.

The first version avoids that problem.

This matters more on smaller integer sizes and very large arrays. Using `lo + (hi - lo) / 2` is the safer form and costs only one subtraction.

## The off-by-one bug

<SnippetSource name="23-competitive.binary-search" decl="stalledLowerBound" />

A common mistake is writing:

`lo = mid`

instead of:

`lo = mid + 1`

At first, this may look reasonable.

If `mid` is too small, we know the answer is not before it.

But we also know that `mid` itself cannot be the answer.

So it must be removed from the search window.

If we keep `mid`, the loop can stop making progress.

When `hi - lo` becomes 1, integer division gives:

`mid == lo`

Now assigning:

`lo = mid`

does not change anything.

The next iteration sees exactly the same values again.

```
  step 3  lo= 3 mid= 4 hi= 6    .   .   .   4[ 7]   7   .   .   .   .   .   .
  step 4  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  step 5  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  step 6  lo= 3 mid= 3 hi= 4    .   .   .[ 4]   .   .   .   .   .   .   .   .
  no progress: gave up at step 6 with lo=3 hi=4
```

Steps four, five, and six are identical.

The example uses a step limit so the program can detect the problem and stop.

Without that limit, the loop would continue indefinitely.

In a competitive programming judge, this normally appears as a time-limit error.

A simple rule helps catch this bug:

The search window must become smaller after every iteration.

In this implementation, both branches reduce the window by at least one index.

## lowerBound and upperBound

<SnippetSource name="23-competitive.binary-search" decl="upperBound" />

`lowerBound` and `upperBound` are almost the same search.

The important difference is the comparison.

`lowerBound` uses `<`.

It finds the first position whose value is greater than or equal to the key.

In other words:

```
first value >= key
```

`upperBound` uses `<=`.

It finds the first position whose value is greater than the key:

```
first value > key
```

If the key appears several times, `lowerBound` points to the first copy and `upperBound` points to the position immediately after the last copy.

Together they create a half-open range:

```
[lowerBound, upperBound)
```

This also makes counting duplicates easy:

```
count = upperBound - lowerBound
```

For example:

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

So there are three copies.

For key `5`, both bounds are 4.

That means the value is not present.

Position 4 is also where `5` would be inserted while keeping the array sorted.

For key `21`, both bounds are 12, which is the end of the array.

This means `21` would be inserted after every existing value.

`lowerBound` is also useful when the value is not present.

It tells us the first position where the value could be inserted.

It can also be used to count how many values are smaller than a given threshold.

## Using the Zig standard library

Zig already provides these operations in `std.sort`.

It includes `lowerBound`, `upperBound`, `equalRange`, and `binarySearch`.

For normal code, you usually do not need to write the binary-search loop yourself.

You do need to provide a comparator.

One detail is easy to miss: the comparator receives the key first and the array element second.

<SnippetSource name="23-competitive.binary-search" decl="orderKeyFirst" />

The argument order matters.

If both arguments have the same type, swapping them may still compile.

But the comparison will mean something different and the result can be wrong.

For the array used in this example:

```
  std.sort.lowerBound(7) = 4, ours = 4
  std.sort.upperBound(7) = 7, ours = 7
  std.sort.equalRange(7) = .{ 4, 7 }
  std.sort.binarySearch(5) = null, lowerBound(5) = 4
```

`std.sort.binarySearch` returns `?usize`.

If the value exists, it returns a matching index.

If the value does not exist, it returns null.

It does not guarantee the first matching index when duplicates exist.

Use `lowerBound` when you need the first matching position.

The final line shows another important difference.

For key `5`:

```
binarySearch(5) = null
```

because `5` is not present.

But:

```
lowerBound(5) = 4
```

because index 4 is where `5` would be inserted.

All of these functions assume that the input is already sorted.

`std.sort` does not check that condition for you.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) covers `std.mem.sort`, the stable and unstable variants, and the context argument these comparators share.

## Reading the example input

<SnippetSource name="23-competitive.binary-search" decl="readRow" />

The examples on this site run under WASI inside the browser.

There is no standard input available in the same way there would be on a normal command-line program.

So the example input is stored in the source file as a string.

`readRow` does not depend directly on that string.

It accepts a `*std.Io.Reader`.

That means the same parsing function can work with different input sources.

The bytes could come from a string, a file, a socket, or standard input.

Only the reader changes.

The parsing code does not.

On a competitive programming judge, you can connect the same parsing function to stdin.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/) covers the interface and the buffer it reads through.
