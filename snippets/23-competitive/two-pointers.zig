//! title: Two Pointers
//! Two indices start at the ends of a sorted array and walk towards each
//! other. Every step prints the pair being held and the part of the array
//! already thrown away, so the traces in the chapter are the traces CI ran.

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
