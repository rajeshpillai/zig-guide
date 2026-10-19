//! title: Prefix Sums and Difference Arrays
//! The prefix array changes a range sum into one subtraction. An extra cell
//! removes the special case at index 0. The difference array uses the same
//! method for range updates, and one pass shows that the two are inverses.
//! The program prints each table. Thus the numbers in the chapter are the
//! numbers that CI ran.

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
