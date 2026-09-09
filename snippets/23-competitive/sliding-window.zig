//! title: Sliding Window
//! Two indices moving the same way over a contiguous run of values. The fixed
//! window that adds one value and subtracts another instead of re-summing, the
//! window that grows and shrinks to find the shortest run reaching a target,
//! and the move counts that show why the inner loop is not a second pass. The
//! program prints every move, so the trace in the chapter is the trace CI ran.

const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. The first line is the values, the second is the window width and the
/// target the second half of the program has to reach.
const input =
    \\2 7 1 9 4 3 8 5 6 2
    \\4 19
;

/// A second array, for the case the shrinking window gets wrong.
///
/// One negative value is enough. `2 + 3` reaches 5 in two values, and the
/// window never sees that pair, because it only ever shrinks a window it has
/// already grown past.
const with_a_negative = [_]i32{ 2, -1, 2, 3 };

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

/// Half-open, so `items[span.lo..span.hi]` is the window and `span.hi` is one
/// past its last value. The same convention the binary search chapter uses.
const Span = struct {
    lo: usize,
    hi: usize,

    fn len(self: Span) usize {
        return self.hi - self.lo;
    }
};

/// Largest sum of `k` consecutive values, by summing every window.
///
/// `adds` counts the additions, because the cost is the point. Each of the
/// `n - k + 1` windows costs `k` additions, so the work grows with the product
/// and a wide window on a long array is slow for no reason.
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

/// The same answer, from one addition and one subtraction per step.
///
/// Two windows a step apart differ by two values: the one that entered on the
/// right and the one that left on the left. Everything between them is in both
/// sums, so re-adding it is work already done. Sum the first window, then keep
/// the total and repair it.
///
/// `i64` and not `i32`. Ten small values fit either way, and a contest array of
/// a hundred thousand values near the limit of `i32` does not.
fn slidingMaxWindow(items: []const i32, k: usize, adds: *usize) ?i64 {
    if (k == 0 or k > items.len) return null;
    var sum: i64 = 0;
    for (items[0..k]) |value| {
        sum += value;
        adds.* += 1;
    }
    var best = sum;
    for (k..items.len) |hi| {
        sum += items[hi]; // entering on the right
        sum -= items[hi - k]; // leaving on the left
        adds.* += 2;
        best = @max(best, sum);
    }
    return best;
}

/// Shortest run of values summing to `target` or more.
///
/// The right edge grows unconditionally, one value per pass. The left edge only
/// moves while the window still qualifies, and every window it passes through is
/// a candidate. `lo` never goes backwards, so each index enters once and leaves
/// at most once and the inner loop cannot run more than `items.len` times over
/// the whole call.
///
/// The shrink rule is what needs the values to be non-negative: dropping a value
/// from the left has to lower the sum, or a window that stopped qualifying might
/// have qualified again later.
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

/// The same answer, from every starting index in turn.
///
/// This one is genuinely quadratic. The outer loop fixes a start, the inner one
/// extends until the sum reaches the target, and the next start throws away
/// everything the previous one learned. `sums` counts the additions so the two
/// numbers can be compared rather than asserted.
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
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i64, width: usize) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The array with the live window drawn into it.
///
/// Four characters per value: a bracket or a space, the value in two, a bracket
/// or a space. Every row lines up, so the window is something to watch move
/// rather than something to reconstruct from two indices.
fn writeWindow(out: *std.Io.Writer, items: []const i32, span: Span) !void {
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

/// One trace row: a label, three counters, then the window.
///
/// A counter of `null` prints a dot, which is what the first row of the fixed
/// trace needs and what the shortest-run trace needs before it has an answer.
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

/// `slidingMaxWindow` with the window printed at every step.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two agree rather than trusting it.
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

/// `shortestAtLeast` with a row per move.
///
/// A `grow` row shows the value that entered and the window after it. A `shrink`
/// row shows the window that just qualified and the value about to leave it, so
/// the candidate the loop recorded is the one on the page.
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

/// Print a span as the values it covers, or say there is no answer.
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

    // A fixed window. The sum is repaired rather than rebuilt.
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

    // A window that changes size. The right edge grows, the left edge shrinks.
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

    // The amortised argument, as two numbers rather than a claim. Every index
    // enters the window once and leaves at most once, so the moves cannot pass
    // 2n however the inner loop happens to run.
    try out.print(
        "  {d} moves over {d} values, ceiling 2n = {d}\n",
        .{ moves, values.len, 2 * values.len },
    );
    try out.print("  {d} additions to try every starting index instead\n\n", .{starts});

    // The shrink rule needs the sum to fall when a value leaves on the left.
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

    // The fixed window is unaffected: it never asks which values to keep.
    var negative_adds: usize = 0;
    try out.print(
        "  largest sum of 2 consecutive values is still {d}\n",
        .{slidingMaxWindow(&with_a_negative, 2, &negative_adds).?},
    );

    try out.flush();
}
