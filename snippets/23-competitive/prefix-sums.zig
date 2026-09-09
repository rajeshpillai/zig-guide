//! title: Prefix Sums and Difference Arrays
//! The prefix array that turns a range sum into one subtraction, the extra
//! cell that removes the special case at index 0, the difference array that
//! does the same trick for range updates, and the pass that shows the two are
//! inverses. The program prints every table, so the numbers in the chapter are
//! the numbers CI ran.

const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. The first line is the values. The second is five ranges as `lo hi`
/// pairs, half-open. The third is three range updates as `lo hi delta`.
const input =
    \\3 1 4 1 5 9 2 6
    \\0 3 2 5 1 8 4 4 0 8
    \\0 3 5 2 6 -1 4 8 10
;

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

/// Half-open, so `items[span.lo..span.hi]` is the range and `span.hi` is one
/// past its last value. The same convention the binary search chapter uses.
const Span = struct {
    lo: usize,
    hi: usize,

    fn len(self: Span) usize {
        return self.hi - self.lo;
    }
};

/// `out[i]` becomes the sum of the first `i` values, so `out` is one cell
/// longer than `items`. The spare cell is what lets a range starting at index
/// 0 be read the same way as any other range.
///
/// `i64` and not `i32`. Eight small values fit either type, and a hundred
/// thousand values near the top of `i32` do not, so the totals get the wider
/// one. `adds` counts the additions, because the build cost is half the
/// argument for using a prefix array at all.
fn buildPrefix(items: []const i32, out: []i64, adds: *usize) []i64 {
    out[0] = 0;
    for (items, 0..) |value, i| {
        out[i + 1] = out[i] + value;
        adds.* += 1;
    }
    return out[0 .. items.len + 1];
}

/// Sum of `items[lo..hi]`, from two reads and a subtraction.
///
/// `pre[hi]` counts everything below `hi` and `pre[lo]` counts everything below
/// `lo`, so the difference is exactly the stretch between them. `lo == hi`
/// gives zero without a branch, and `lo == 0` reads `pre[0]`, which the spare
/// cell already set to zero.
fn rangeSum(pre: []const i64, span: Span) i64 {
    return pre[span.hi] - pre[span.lo];
}

/// The same sum, by adding the values up.
///
/// Kept so the two can be compared rather than trusted, and so the additions
/// can be counted against the ones `buildPrefix` charged.
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
/// `diff` is one cell longer than the array it describes, for the same reason
/// the prefix array is: an update running to the last index writes its closing
/// mark at `items.len`, and that cell has to exist.
///
/// Nothing about the cost depends on how wide the range is. A range covering
/// the whole array is two writes, and so is a range covering one value.
fn applyRange(diff: []i64, span: Span, delta: i64) void {
    diff[span.lo] += delta;
    diff[span.hi] -= delta;
}

/// Running sum of `diff`, which is the values it was recording all along.
///
/// The last cell of `diff` never contributes a value. It exists to cancel the
/// deltas that opened, so after the pass the running total is back at zero.
fn accumulate(diff: []const i64, out: []i32) []i32 {
    var running: i64 = 0;
    for (diff[0 .. diff.len - 1], 0..) |value, i| {
        running += value;
        out[i] = @intCast(running);
    }
    return out[0 .. diff.len - 1];
}

/// The gap between each value and the one before it.
///
/// The inverse of `accumulate`: run this over an array and accumulate the
/// result, and the original comes back. `out[items.len]` closes the array off
/// by subtracting the last value.
fn difference(items: []const i32, out: []i64) []i64 {
    var previous: i64 = 0;
    for (items, 0..) |value, i| {
        out[i] = value - previous;
        previous = value;
    }
    out[items.len] = -previous;
    return out[0 .. items.len + 1];
}

/// Apply every update the slow way, writing each cell of each range.
///
/// The reference the difference array has to agree with. Its cost is the sum
/// of the range widths, which is what the two writes per update replace.
fn applyRangesDirectly(out: []i32, spans: []const Span, deltas: []const i64) []i32 {
    @memset(out, 0);
    for (spans, deltas) |span, delta| {
        for (out[span.lo..span.hi]) |*cell| cell.* += @intCast(delta);
    }
    return out;
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i64, width: usize) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The array with one range drawn into it.
///
/// Four characters per value: a bracket or a space, the value in two, a bracket
/// or a space. An empty range draws no brackets at all, which is what `[4,4)`
/// looks like on the page.
fn writeRange(out: *std.Io.Writer, items: []const i32, span: Span) !void {
    const inside = span.lo < span.hi;
    for (items, 0..) |value, i| {
        try out.writeByte(if (inside and i == span.lo) '[' else ' ');
        try writeCell(out, value, 2);
        const closing: u8 = if (inside and i + 1 == span.hi) ']' else ' ';
        // No trailing space at the end of a row: the expected output is diffed
        // byte for byte, and an invisible column is a bad thing to depend on.
        if (closing == ' ' and i + 1 == items.len) break;
        try out.writeByte(closing);
    }
}

/// A labelled row of `i64` cells, four characters each.
///
/// The label field is 13 wide so the update trace lines up under a header of
/// column numbers, which is the only way to see which two cells a range update
/// touched.
fn writeWideRow(out: *std.Io.Writer, label: []const u8, cells: []const i64) !void {
    try out.print("  {s: <13}", .{label});
    for (cells) |value| try writeCell(out, value, 4);
    try out.writeByte('\n');
}

/// A labelled row of `i32` cells, four characters each.
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

    // The build. One pass, one addition per value, one cell more than the
    // array it summarises.
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

    // Each query is two reads and a subtraction, whatever the range covers.
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

    // The build is only free once. An array that changes between queries pays
    // for it again every time, and then the loop is cheaper.
    try out.writeAll("what the build costs, against what it saves\n");
    var plan: [40]u8 = undefined;
    const built_once = try std.mem.print(&plan, "build once, then {d} lookups", .{queries.len});
    try out.print("  {s: <28}{d:>4} adds\n", .{ built_once, build_adds });
    try out.print("  {s: <28}{d:>4} adds\n", .{ "rebuild before each lookup", build_adds * queries.len });
    try out.print("  {s: <28}{d:>4} adds\n\n", .{ "no prefix array at all", loop_adds });

    // The mirror image. Two writes record a change across a whole range.
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

    // One pass reads the totals back out.
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

    // The two operations undo each other, so the round trip is a check on both.
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
