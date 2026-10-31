# Two Pointers

> Two indices that start at opposite ends, and the argument that tells which index must move.

The input is a sorted array and a target sum. The task is to find two values with a sum that is equal to the target.

One method is to try each possible pair. That method takes O(n²) time. For an array with 100,000 values, the number of comparisons is much too large.

The values are in ascending order. Thus a better method is possible:

1. Put one index at the start and a second index at the end.
2. Add the two values.
3. Use the result to move one of the indices toward the center.

Each step removes one value from the search.

The trace below shows each step. Marks show the two active indices. A dot shows a position that the search removed.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A browser tab under WASI has no stdin. Thus the file holds the four lines
/// that a judge gives to the program. The lines are the sorted values, the
/// target sums, some words for the palindrome test, and a row of heights for
/// the last section.
const input =
    \\2 3 5 8 11 17 20 24
    \\25 5 44 31 100 4
    \\racecar level abcba noon zig
    \\1 8 6 2 5 4 8 3 7
;

/// One line, or an error if the input has no more lines.
fn readLine(reader: *std.Io.Reader) ![]const u8 {
    return (try reader.takeDelimiter('\n')) orelse error.MissingRow;
}

/// Read one line of whitespace-separated integers into `out`.
///
/// The parameter is a `*std.Io.Reader`, not a string. Thus the same function
/// reads a file on a judge and a literal here. Only the reader changes.
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

/// The indices of two values with the sum `target`, or null.
///
/// `items` must be sorted. Because of the sort, only one move is correct.
///
/// The value at `hi` is the largest partner for `lo` in the range. Thus a sum
/// below the target shows that `lo` is in no pair, and `lo` moves up. The
/// value at `lo` is the smallest partner for `hi` in the range. Thus a sum
/// above the target shows the same about `hi`, and `hi` moves down.
///
/// Each step removes one index permanently. Thus the search is a single pass.
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
/// A width on a signed integer also prints a sign. Thus `{d:>4}` shows 7 as
/// `  +7`. This function writes the digits first and adds the padding by hand.
/// Thus the columns do not show plus signs.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The array with the current range: `>` at `lo`, `<` at `hi`, and a dot for
/// each index that the search removed.
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

/// The same search as `twoSum`, but it prints the pair and the result at each
/// step.
///
/// The print calls are here. Thus `twoSum` keeps the shape that you can copy
/// into a solution. The function also returns the number of steps, because
/// that number is the claim to check: it never gets to the length of the
/// array.
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

/// True when `text` is the same in the two directions.
///
/// The movement is the same as above, with a different comparison. When the
/// bytes at the two ends are equal, the two positions are complete. Thus the
/// two indices move, and the middle part becomes two bytes smaller. When two
/// bytes are not equal, the search stops, because that pair is a pair in each
/// direction of the string.
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

/// `isPalindrome`, but each checked byte prints as a dot.
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

/// The largest rectangle between two of `heights`: the water between two
/// walls on a flat floor.
///
/// The area is the shorter wall times the distance. Thus the shorter wall
/// limits the area. Each other pair with that wall is narrower than the pair
/// that the function measured, and it is not taller. Thus no such pair has a
/// larger area, and the function can remove the wall. The trace prints the
/// side that moved.
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

    // The search with a trace, and the search without a trace. The two
    // results must agree.
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

    // Each step removes one index. Thus the length of the array limits the
    // number of steps, for all values.
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

    // The same movement on bytes.
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

    // To remove a candidate, the search needs a reason. Here the reason
    // shows that the search can remove the shorter wall.
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

## Decide which pointer moves

```zig
/// The indices of two values with the sum `target`, or null.
///
/// `items` must be sorted. Because of the sort, only one move is correct.
///
/// The value at `hi` is the largest partner for `lo` in the range. Thus a sum
/// below the target shows that `lo` is in no pair, and `lo` moves up. The
/// value at `lo` is the smallest partner for `hi` in the range. Thus a sum
/// above the target shows the same about `hi`, and `hi` moves down.
///
/// Each step removes one index permanently. Thus the search is a single pass.
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
```

*Quoted from the source: `twoSum` from `snippets/23-competitive/two-pointers.zig`.*

`lo` and `hi` mark the part of the array that the search did not remove. The current range is `items[lo..hi + 1]`. The search removed each value outside this range.

At each step, the loop calculates `items[lo] + items[hi]`. There are three possible cases:

- If the sum is equal to the target, the loop has the answer.
- If the sum is smaller than the target, `lo` must move.
- If the sum is larger than the target, `hi` must move.

When the sum is too small, look at `items[hi]`. It is the largest value in the range that can be a pair with `items[lo]`. If that pair is too small, no other value in the range can make a sufficiently large sum with `items[lo]`. Thus `items[lo]` cannot be part of the answer. The loop removes it with `lo += 1`.

When the sum is too large, look at `items[lo]`. It is the smallest value in the range that can be a pair with `items[hi]`. If that pair is already too large, each other possible partner for `items[hi]` gives an equal or larger sum. Thus `items[hi]` cannot be part of the answer. The loop removes it with `hi -= 1`.

Each step removes exactly one index from the search. The two pointers never move backward. Thus the distance between `lo` and `hi` becomes smaller on each iteration, and the loop runs O(n) times or fewer.

This argument is correct only when the values are in ascending order. If they are not in order, a move of `lo` or `hi` tells you nothing about the values in the range. The function does not check the order of the values. Thus sort the input first.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) explains `std.mem.sort` and its comparator.

In this example, the two pointers start at opposite ends and move toward each other. A different common pattern has two pointers that move in the same direction, with a contiguous range between them. [Sliding Window](https://www.ziglang.in/learn/competitive-programming/sliding-window/) explains that pattern.

## Follow the search

```zig
/// The same search as `twoSum`, but it prints the pair and the result at each
/// step.
///
/// The print calls are here. Thus `twoSum` keeps the shape that you can copy
/// into a solution. The function also returns the number of steps, because
/// that number is the claim to check: it never gets to the length of the
/// array.
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
```

*Quoted from the source: `traceTwoSum` from `snippets/23-competitive/two-pointers.zig`.*

`>` marks `lo`, and `<` marks `hi`. A dot shows a position that the search removed:

```
  step 1   2 + 24 =  26  too big    >  2   3   5   8  11  17  20 24<
  step 2   2 + 20 =  22  too small  >  2   3   5   8  11  17 20<   .
  step 3   3 + 20 =  23  too small     .>  3   5   8  11  17 20<   .
  step 4   5 + 20 =  25  match         .   .>  5   8  11  17 20<   .
```

The trace has four steps:

1. The sum is too large. Thus the search moves `hi` and removes 24.
2. The sum is too small. Thus the search moves `lo` and removes 2.
3. The sum is too small again. Thus the search removes 3.
4. `5 + 20` is equal to the target.

The two ends do not have to move at the same rate. The current sum alone decides which pointer moves.

The same search for each target on the second input line gives these results:

```
  target    pair    values  steps
      25   2, 6    5 + 20      4
       5   0, 1    2 +  3      7
      44   6, 7   20 + 24      7
      31   4, 6   11 + 20      6
     100     -          -      7
       4     -          -      7
```

The array has eight values. No search takes more than seven steps. This is also true when no pair has the target sum.

For target 100, each possible sum is too small. For target 4, each possible sum is too large. The pointers move until they meet. If they meet and the search did not find the target, no pair has the target sum.

## Use the same method for a palindrome

```zig
/// True when `text` is the same in the two directions.
///
/// The movement is the same as above, with a different comparison. When the
/// bytes at the two ends are equal, the two positions are complete. Thus the
/// two indices move, and the middle part becomes two bytes smaller. When two
/// bytes are not equal, the search stops, because that pair is a pair in each
/// direction of the string.
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
```

*Quoted from the source: `isPalindrome` from `snippets/23-competitive/two-pointers.zig`.*

You can use the same two-pointer structure with strings. Do not add the values at the two ends. Compare them.

One pointer starts at the first byte. The other pointer starts at the last byte. If the two bytes are equal, move the two pointers toward the center.

For `racecar`, the search has these steps:

```
  step 1  r = r  >r  a  c  e  c  a  r<
  step 2  a = a   . >a  c  e  c  a< .
  step 3  c = c   .  . >c  e  c< .  .
  3 steps, nothing left to pair
```

The string has seven bytes, but the function needs only three comparisons. The function does not compare the middle `e` with a different byte. The condition `while (lo < hi)` stops before the middle value.

If the two sides are not equal, the function can return `false` immediately:

```
  step 1  z ! g  >z  i  g<
```

The function does not have to check the other bytes. In a palindrome, each pair from the outside to the center must be equal. Thus one pair that is not equal proves that the string is not a palindrome.

This implementation compares bytes. For ASCII text, one character is one byte. Thus the function gives the correct result.

For Unicode text, a character can use more than one byte. For example, the characters of `été` are the same in the two directions. But the UTF-8 bytes of `été` are not all single-byte characters. For general Unicode text, decode the string into code points before you use the same two-pointer method.

## Container with most water

```zig
/// The largest rectangle between two of `heights`: the water between two
/// walls on a flat floor.
///
/// The area is the shorter wall times the distance. Thus the shorter wall
/// limits the area. Each other pair with that wall is narrower than the pair
/// that the function measured, and it is not taller. Thus no such pair has a
/// larger area, and the function can remove the wall. The trace prints the
/// side that moved.
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
```

*Quoted from the source: `maxArea` from `snippets/23-competitive/two-pointers.zig`.*

The same pattern solves the container-with-most-water problem. Each number is the height of a vertical wall. For two walls at positions `lo` and `hi`, the shorter wall limits the quantity of water between them.

The area has these parts:

- The width is `hi - lo`.
- The height is `@min(heights[lo], heights[hi])`.
- Thus the area is `@min(heights[lo], heights[hi]) * (hi - lo)`.

The search starts with the widest possible pair: the first wall and the last wall. After that, each move makes the width smaller. Thus a move is useful only if it can find a taller wall. This rule decides which pointer moves.

For example, `heights[lo]` is the shorter wall. Each new pair that keeps `lo` has a smaller width. Its height can never be greater than `heights[lo]`, because the height of a pair is never more than the height of either wall. Thus no pair that keeps this wall can have a larger area than the pair that the search already measured.

Thus the search can safely remove `lo`. The same argument applies to `hi` when the right wall is shorter.

The program prints the first four steps:

```
  step   lo   hi  h[lo]  h[hi]  width  area  best  moved
     1    0    8     1     7      8     8     8  lo
     2    1    8     8     7      7    49    49  hi
     3    1    7     8     3      6    18    49  hi
     4    1    6     8     8      5    40    49  hi
```

At step one, the left wall is shorter. Thus `lo` moves. At step two, the right wall is shorter. Thus `hi` moves, and the best area becomes 49.

At step four, the two walls have the same height. In this case, either pointer can move. The code moves `hi` because of the form of the comparison, but a move of `lo` is also correct.

Always move the shorter wall. A move of the taller wall can work for some inputs. But it can remove a pair that has the maximum area.

The figure plays all eight steps. The shaded area is the water between `lo` and `hi`. After step 2, a dashed outline keeps the best area on the drawing.

*Figure: Nine walls of heights 1, 8, 6, 2, 5, 4, 8, 3, 7. The water between lo and hi is drawn at each step, and a dashed outline marks the best area. The trace from the program above. At each step, the shaded area is the water between the two walls, and the lower wall moves.*
