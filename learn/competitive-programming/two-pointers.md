# Two Pointers

> Two indices starting at opposite ends, and the argument that says which one of them has to move.

Suppose we have a sorted array and a target sum.

We need to find two values whose sum equals the target.

One way is to try every possible pair. That takes O(n²) time.

For an array with 100,000 values, that is far too many comparisons.

Because the array is sorted, we can do better.

Place one index at the beginning and another at the end. Add the two values. Based on the result, move one of the indices inward.

Each step removes one value from consideration.

The trace below shows every step. The two active indices are marked, and positions that have already been ruled out are shown as dots.

```zig
const std = @import("std");

/// The problem, as text.
///
/// There is no stdin under WASI in a browser tab, so the four lines a judge
/// would feed the program live in the file instead: the sorted values, the
/// target sums to look for, some words to test for symmetry, and a row of
/// heights for the last section.
const input =
    \\2 3 5 8 11 17 20 24
    \\25 5 44 31 100 4
    \\racecar level abcba noon zig
    \\1 8 6 2 5 4 8 3 7
;

/// One line, or an error if the input ran out.
fn readLine(reader: *std.Io.Reader) ![]const u8 {
    return (try reader.takeDelimiter('\n')) orelse error.MissingRow;
}

/// Read one line of whitespace-separated integers into `out`.
///
/// The parameter is a `*std.Io.Reader` and not a string, so the same function
/// reads a file on a judge and a literal here. Only the reader passed in
/// changes.
fn readRow(reader: *std.Io.Reader, out: []i32) ![]i32 {
    const line = try readLine(reader);
    var count: usize = 0;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        if (count == out.len) return error.RowTooLong;
        out[count] = try std.fmt.parseInt(i32, field, 10);
        count += 1;
    }
    return out[0..count];
}

/// Indices of two values that add up to `target`, or null.
///
/// `items` must be sorted, and the sorting is what leaves only one move. The
/// value at `hi` is the largest partner `lo` has left, so a sum below the
/// target says `lo` is in no pair at all and `lo` moves up. The value at `lo`
/// is the smallest partner `hi` has left, so a sum above the target says the
/// same about `hi` and `hi` moves down. Each step drops one index for good,
/// which is what keeps the whole search to a single pass.
fn twoSum(items: []const i32, target: i32) ?[2]usize {
    if (items.len < 2) return null;
    var lo: usize = 0;
    var hi: usize = items.len - 1;
    while (lo < hi) {
        const sum = items[lo] + items[hi];
        if (sum == target) return .{ lo, hi };
        if (sum < target) lo += 1 else hi -= 1;
    }
    return null;
}

/// Right-align a value in a cell of `width` characters.
///
/// A width on a signed integer prints a sign with it, so `{d:>4}` renders 7 as
/// `  +7`. Writing the digits first and padding them by hand keeps the columns
/// free of plus signs nobody asked for.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The array with the live range drawn in: `>` at `lo`, `<` at `hi`, and a dot
/// for every index the search has already discarded.
fn writeWindow(out: *std.Io.Writer, items: []const i32, lo: usize, hi: usize) !void {
    for (items, 0..) |value, i| {
        if (i < lo or i > hi) {
            try out.writeAll("   .");
        } else if (i == lo) {
            try out.writeByte('>');
            try writeCell(out, value, 3);
        } else if (i == hi) {
            try writeCell(out, value, 3);
            try out.writeByte('<');
        } else {
            try writeCell(out, value, 4);
        }
    }
    try out.writeByte('\n');
}

const Search = struct { pair: ?[2]usize, steps: usize };

/// The same walk as `twoSum`, printing the pair and the verdict at each step.
///
/// The printing lives here so `twoSum` stays the shape you would paste into a
/// solution. The step count comes back with the answer, because the count is
/// the claim worth checking: it never reaches the length of the array.
fn traceTwoSum(out: *std.Io.Writer, items: []const i32, target: i32) !Search {
    if (items.len < 2) return .{ .pair = null, .steps = 0 };
    var lo: usize = 0;
    var hi: usize = items.len - 1;
    var steps: usize = 0;
    while (lo < hi) {
        const sum = items[lo] + items[hi];
        steps += 1;
        try out.print("  step {d}  ", .{steps});
        try writeCell(out, items[lo], 2);
        try out.writeAll(" + ");
        try writeCell(out, items[hi], 2);
        try out.writeAll(" = ");
        try writeCell(out, sum, 3);
        const verdict = if (sum == target) "match" else if (sum < target) "too small" else "too big";
        try out.print("  {s}", .{verdict});
        try out.splatByteAll(' ', 11 - verdict.len);
        try writeWindow(out, items, lo, hi);
        if (sum == target) return .{ .pair = .{ lo, hi }, .steps = steps };
        if (sum < target) lo += 1 else hi -= 1;
    }
    return .{ .pair = null, .steps = steps };
}

/// True when `text` reads the same in both directions.
///
/// The movement is the one above with the comparison changed. Equal bytes at
/// the two ends settle both positions at once, so both indices move and the
/// untested middle shrinks by two. A mismatch ends the walk, because the pair
/// that failed is a pair in every reading of the string.
fn isPalindrome(text: []const u8) bool {
    if (text.len == 0) return true;
    var lo: usize = 0;
    var hi: usize = text.len - 1;
    while (lo < hi) {
        if (text[lo] != text[hi]) return false;
        lo += 1;
        hi -= 1;
    }
    return true;
}

/// `isPalindrome` with the settled bytes printed as dots.
fn tracePalindrome(out: *std.Io.Writer, text: []const u8) !bool {
    if (text.len == 0) return true;
    var lo: usize = 0;
    var hi: usize = text.len - 1;
    var steps: usize = 0;
    while (lo < hi) {
        steps += 1;
        const matched = text[lo] == text[hi];
        try out.print("  step {d}  {c} {s} {c}  ", .{
            steps,
            text[lo],
            if (matched) "=" else "!",
            text[hi],
        });
        var row_buf: [256]u8 = undefined;
        var row: std.Io.Writer = .fixed(&row_buf);
        for (text, 0..) |byte, i| {
            if (i < lo or i > hi) {
                try row.writeAll(" . ");
            } else if (i == lo) {
                try row.print(">{c} ", .{byte});
            } else if (i == hi) {
                try row.print(" {c}<", .{byte});
            } else {
                try row.print(" {c} ", .{byte});
            }
        }
        try out.writeAll(std.mem.trimEnd(u8, row.buffered(), " "));
        try out.writeByte('\n');
        if (!matched) return false;
        lo += 1;
        hi -= 1;
    }
    try out.print("  {d} steps, nothing left to pair\n", .{steps});
    return true;
}

const Area = struct { best: i32, lo: usize, hi: usize };

/// The largest rectangle between two of `heights`, water held between two
/// walls on a flat floor.
///
/// The area is the shorter wall times the distance, so the shorter wall is the
/// one that limits it. Every pair still containing that wall is narrower than
/// the pair just measured and no taller, so none of them can beat it, and the
/// wall can be dropped. The trace prints the side that moved.
fn maxArea(out: *std.Io.Writer, heights: []const i32) !Area {
    if (heights.len < 2) return .{ .best = 0, .lo = 0, .hi = 0 };
    var lo: usize = 0;
    var hi: usize = heights.len - 1;
    var found: Area = .{ .best = 0, .lo = 0, .hi = 0 };
    var steps: usize = 0;
    while (lo < hi) {
        const height = @min(heights[lo], heights[hi]);
        const width: i32 = @intCast(hi - lo);
        const area = height * width;
        if (area > found.best) found = .{ .best = area, .lo = lo, .hi = hi };
        steps += 1;
        const shorter_is_left = heights[lo] < heights[hi];
        try out.print("  {d:>4}  {d:>3}  {d:>3}", .{ steps, lo, hi });
        try writeCell(out, heights[lo], 6);
        try writeCell(out, heights[hi], 6);
        try writeCell(out, width, 7);
        try writeCell(out, area, 6);
        try writeCell(out, found.best, 6);
        try out.print("  {s}\n", .{if (shorter_is_left) "lo" else "hi"});
        if (shorter_is_left) lo += 1 else hi -= 1;
    }
    return found;
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    var target_storage: [64]i32 = undefined;
    var height_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);
    const targets = try readRow(&reader, &target_storage);
    const words = try readLine(&reader);
    const heights = try readRow(&reader, &height_storage);

    try out.print("{d} sorted values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // The traced walk, and the untraced one it has to agree with.
    try out.writeAll("two values that add up to 25\n");
    const traced = try traceTwoSum(out, values, 25);
    const pair = traced.pair.?;
    try out.print(
        "  items[{d}] + items[{d}] = {d} + {d} = 25 in {d} steps\n",
        .{ pair[0], pair[1], values[pair[0]], values[pair[1]], traced.steps },
    );
    try out.print(
        "  plain twoSum agrees -> {}\n\n",
        .{std.meta.eql(twoSum(values, 25), traced.pair)},
    );

    // One step retires one index, so the step count is bounded by the length
    // of the array however the values fall.
    try out.writeAll("every target, with the steps it cost\n");
    try out.writeAll("  target    pair    values  steps\n");
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var worst: usize = 0;
    for (targets) |target| {
        const found = try traceTwoSum(&sink.writer, values, target);
        worst = @max(worst, found.steps);
        try writeCell(out, target, 8);
        if (found.pair) |p| {
            try out.print("  {d:>2},{d:>2}   ", .{ p[0], p[1] });
            try writeCell(out, values[p[0]], 2);
            try out.writeAll(" +");
            try writeCell(out, values[p[1]], 3);
        } else {
            try out.writeAll("     -          -");
        }
        try out.print("  {d:>5}\n", .{found.steps});
    }
    try out.print("  one index retires per step, so {d} values allow {d} steps at most\n", .{
        values.len,
        values.len - 1,
    });
    try out.print("  the worst row above took {d}\n\n", .{worst});

    // The same movement over bytes.
    try out.writeAll("racecar, checked from both ends\n");
    const symmetric = try tracePalindrome(out, "racecar");
    try out.print("  palindrome -> {}\n\n", .{symmetric});

    try out.writeAll("zig, where the first pair already answers it\n");
    const asymmetric = try tracePalindrome(out, "zig");
    try out.print("  palindrome -> {}\n\n", .{asymmetric});

    try out.writeAll("every word on the third input line\n");
    var word_fields = std.mem.tokenizeScalar(u8, words, ' ');
    while (word_fields.next()) |word| {
        try out.print("  {s:<9}{}\n", .{ word, isPalindrome(word) });
    }
    try out.writeAll("\n");

    // Discarding a candidate needs an argument, not a hunch. Here it is the
    // shorter wall that can be thrown away.
    try out.writeAll("most water between two walls\n");
    try out.writeAll("  step   lo   hi  h[lo]  h[hi]  width  area  best  moved\n");
    const water = try maxArea(out, heights);
    try out.print("  best {d} between index {d} and index {d}\n", .{
        water.best,
        water.lo,
        water.hi,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.two-pointers`)*

## Deciding which pointer moves

<SnippetSource name="23-competitive.two-pointers" decl="twoSum" />

`lo` and `hi` mark the part of the array that is still being considered.

The current range is:

`items[lo..hi + 1]`

Everything outside this range has already been ruled out.

At each step, we calculate:

`items[lo] + items[hi]`

There are three possible cases.

If the sum equals the target, we have found the answer.

If the sum is smaller than the target, `lo` must move.

`items[hi]` is the largest value that can still be paired with `items[lo]`.

If even that pair is too small, then no other remaining value can make a large enough sum with `items[lo]`.

So `items[lo]` cannot be part of the answer.

We remove it by moving:

`lo += 1`

If the sum is larger than the target, `hi` must move.

`items[lo]` is the smallest value that can still be paired with `items[hi]`.

If that pair is already too large, then every other possible partner for `items[hi]` will produce an equal or larger sum.

So `items[hi]` cannot be part of the answer.

We remove it by moving:

`hi -= 1`

Each step removes exactly one index from the search.

Neither pointer ever moves backwards.

The distance between `lo` and `hi` becomes smaller on every iteration.

So the loop runs at most O(n) times.

The brute-force approach checks pairs and takes O(n²).

The two-pointer approach makes one pass and takes O(n).

This reasoning depends on the array being sorted.

If the array is not sorted, moving `lo` or `hi` no longer tells us anything about the values that remain.

The function does not check whether the array is sorted, so sort the input first.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) covers `std.mem.sort` and the comparator it takes.

In this example, the two pointers start at opposite ends and move towards each other.

Another common pattern uses two pointers moving in the same direction while maintaining a contiguous range between them.

That pattern is covered in [Sliding Window](https://www.ziglang.in/learn/competitive-programming/sliding-window/).

## Following the search

<SnippetSource name="23-competitive.two-pointers" decl="traceTwoSum" />

`>` marks `lo`, `<` marks `hi`, and dots show positions that have already been removed from consideration:

```
  step 1   2 + 24 =  26  too big    >  2   3   5   8  11  17  20 24<
  step 2   2 + 20 =  22  too small  >  2   3   5   8  11  17 20<   .
  step 3   3 + 20 =  23  too small     .>  3   5   8  11  17 20<   .
  step 4   5 + 20 =  25  match         .   .>  5   8  11  17 20<   .
```

At step one, the sum is too large, so 24 is removed by moving `hi`.

At step two, the sum is too small, so 2 is removed by moving `lo`.

At step three, the sum is still too small, so 3 is removed.

At step four, `5 + 20` equals the target.

The two ends do not have to move at the same rate.

Which pointer moves depends entirely on the current sum.

Running the same search for every target on the second input line gives:

```
  target    pair    values  steps
      25   2, 6    5 + 20      4
       5   0, 1    2 +  3      7
      44   6, 7   20 + 24      7
      31   4, 6   11 + 20      6
     100     -          -      7
       4     -          -      7
```

The array has eight values.

No search takes more than seven steps.

That is true even when there is no matching pair.

For target 100, every possible sum is too small.

For target 4, every possible sum is too large.

The pointers keep moving until they meet.

If they meet without finding the target, no valid pair exists.

## The same idea for a palindrome

<SnippetSource name="23-competitive.two-pointers" decl="isPalindrome" />

The same two-pointer structure can be used with strings.

Instead of adding the values at the two ends, compare them.

One pointer starts at the first byte.

The other starts at the last byte.

If the two bytes match, move both pointers inward.

For example:

```
  step 1  r = r  >r  a  c  e  c  a  r<
  step 2  a = a   . >a  c  e  c  a< .
  step 3  c = c   .  . >c  e  c< .  .
  3 steps, nothing left to pair
```

The string has seven bytes.

Only three comparisons are needed.

The middle `e` does not need to be compared with anything.

The condition:

`while (lo < hi)`

naturally stops before the middle value.

If the two sides do not match, the function can return `false` immediately:

```
  step 1  z ! g  >z  i  g<
```

There is no need to check the remaining bytes.

A palindrome requires every matching pair from the outside inward to be equal.

One mismatch is enough to prove that the string is not a palindrome.

This implementation compares bytes.

For ASCII text, one character is one byte, so this works as expected.

For Unicode text, a character may use multiple bytes.

For example, `été` looks the same forwards and backwards as characters, but its UTF-8 bytes are not arranged as single-byte characters.

For general Unicode text, decode the string into code points before applying the same two-pointer idea.

## Container with most water

<SnippetSource name="23-competitive.two-pointers" decl="maxArea" />

The same pattern appears in the container-with-most-water problem.

Each number represents the height of a vertical wall.

For two walls at positions `lo` and `hi`, the amount of water they can hold is limited by the shorter wall.

The width is:

`hi - lo`

The height is:

`@min(heights[lo], heights[hi])`

So the area is:

`@min(heights[lo], heights[hi]) * (hi - lo)`

We start with the widest possible pair: the first and last walls.

After that, every move makes the width smaller.

So if we move a pointer, we need a chance to find a taller wall.

This tells us which pointer should move.

Suppose `heights[lo]` is shorter.

Any new pair that keeps `lo` will have a smaller width.

Its height can never be greater than `heights[lo]`, because `lo` is still the shorter wall.

So no pair that keeps this wall can produce a better area than the one we have already checked.

We can safely remove `lo`.

The same reasoning applies to `hi` when the right wall is shorter.

For example:

```
  step   lo   hi  h[lo]  h[hi]  width  area  best  moved
     1    0    8     1     7      8     8     8  lo
     2    1    8     8     7      7    49    49  hi
     3    1    7     8     3      6    18    49  hi
     4    1    6     8     8      5    40    49  hi
```

At step one, the left wall is shorter, so `lo` moves.

At step two, the right wall is shorter, so `hi` moves.

The best area becomes 49.

At step four, both walls have the same height.

In that case, either pointer can move.

The code moves `hi` because of how the comparison is written, but moving `lo` would also be valid.

The important rule is to move the shorter wall.

Moving the taller wall is not safe.

It may work for some inputs, but it can remove a pair that would have produced the maximum area.
