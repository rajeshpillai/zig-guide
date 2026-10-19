//! title: Binary Search
//! The half-open window, the invariant that keeps the window correct, and the
//! two bounds that tell where a value starts and where it ends. The program
//! prints each step. Thus the trace in the chapter is the trace that CI ran.

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
