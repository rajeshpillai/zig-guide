//! title: Binary Search
//! The half-open window, the invariant that keeps it correct, and the two
//! bounds that answer where a value starts and where it ends. The program
//! prints every step it takes, so the trace in the chapter is the trace CI ran.

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
