//! title: The Monotonic Stack
//! A stack of indices with values that become smaller from bottom to top.
//! Thus one pass answers a question that looks like it needs a scan from each
//! index. The program prints the push, the pops and the stack after each
//! step. It also prints the counters for the amortised argument. Thus the
//! trace in the chapter is the trace that CI ran.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The problem needs only one line of values. The parser below reads
/// the line in the same way that it reads a real file.
const input =
    \\3 1 4 1 5 9 2 6 5 3 7
;

/// The worst array for a scan and the easiest array for the stack.
///
/// No value has a greater value to its right. Thus the scan goes to the end
/// from each index, and the stack never pops.
const decreasing = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The opposite of `decreasing`. The scan stops at its first comparison each
/// time. The stack pops the index that it pushed on the step before.
const increasing = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

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

/// The two counters that the amortised argument uses.
///
/// The count costs two lines. It answers a question that is easy to get wrong
/// if you only think about the nested loop.
const Work = struct {
    pushes: usize = 0,
    pops: usize = 0,
};

/// For each index, the index of the first greater value to its right.
///
/// The direct solution. Select an index, then move right to a greater value,
/// or stop at the end of the array. `comparisons` counts the values that the
/// scan examines. This number increases with the square of the input size.
fn scanRight(items: []const i32, out: []?usize, comparisons: *usize) void {
    for (items, 0..) |value, i| {
        out[i] = null;
        for (items[i + 1 ..], i + 1..) |other, j| {
            comparisons.* += 1;
            if (other > value) {
                out[i] = j;
                break;
            }
        }
    }
}

/// The same answers from one pass over the array.
///
/// The stack holds the indices that do not have an answer yet. The values of
/// these indices become smaller from bottom to top. When `value` comes, each
/// index on the stack with a smaller value has its answer. Because of the
/// order, these indices are together at the top. Pop them, record `i`, and
/// push `i`.
///
/// The loop itself keeps the order. Each index that stays after the pops has
/// a value that is equal to or larger than `value`. Thus with `i` on top, the
/// values on the stack still become smaller from bottom to top.
///
/// Use `>=`, not `>`. An equal value is not greater. Thus a second 7 does not
/// answer an index that waits for a value greater than 7.
///
/// The loop never writes the indices that are still on the stack at the end
/// of the array. Before the loop, `@memset` set each item in `out` to null.
/// Thus an index without an answer does not need a separate case.
fn nextGreater(gpa: Allocator, items: []const i32, out: []?usize, work: *Work) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    @memset(out, null);

    for (items, 0..) |value, i| {
        while (stack.last()) |top| {
            if (items[top] >= value) break;
            out[top] = i;
            _ = stack.pop();
            work.pops += 1;
        }
        try stack.append(gpa, i);
        work.pushes += 1;
    }
}

/// The first smaller value to the left, from the same method.
///
/// There are two changes. First, the comparison is the opposite. Thus the
/// values on the stack become larger from bottom to top. Second, the answer
/// comes from the index that stays on the stack, not from the popped indices.
/// After the pops, the index on top is the nearest index to the left with a
/// smaller value.
fn previousSmaller(gpa: Allocator, items: []const i32, out: []?usize, work: *Work) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    @memset(out, null);

    for (items, 0..) |value, i| {
        while (stack.last()) |top| {
            if (items[top] < value) break;
            _ = stack.pop();
            work.pops += 1;
        }
        out[i] = stack.last();
        try stack.append(gpa, i);
        work.pushes += 1;
    }
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the columns are easy to read.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// A value that can be absent, right-aligned. A dot means no answer.
fn writeMaybe(out: *std.Io.Writer, value: ?i32, width: usize) !void {
    if (value) |v| return writeCell(out, v, width);
    try out.splatByteAll(' ', width - 1);
    try out.writeByte('.');
}

/// The stack, bottom to top, as `index:value` pairs.
///
/// The values next to the indices show the order. A column of only indices
/// hides the property that the method needs.
fn writeStack(out: *std.Io.Writer, items: []const i32, indices: []const usize) !void {
    for (indices, 0..) |idx, k| {
        if (k > 0) try out.writeByte(' ');
        try out.print("{d}:{d}", .{ idx, items[idx] });
    }
}

/// The indices that this step resolved, each with its answer.
///
/// All these indices get the same answer, because the same new value popped
/// them. The row shows the answer for each index. Thus the row is easy to
/// compare with the answers table below.
fn writeResolved(out: *std.Io.Writer, popped: []const usize, answer: i32, width: usize) !void {
    var used: usize = 0;
    if (popped.len == 0) {
        try out.writeByte('.');
        used = 1;
    }
    for (popped, 0..) |idx, k| {
        if (k > 0) {
            try out.writeAll(", ");
            used += 2;
        }
        var digits: [24]u8 = undefined;
        const text = try std.mem.print(&digits, "{d} -> {d}", .{ idx, answer });
        try out.writeAll(text);
        used += text.len;
    }
    try out.splatByteAll(' ', width - used);
}

/// `nextGreater`, but it prints a row for each new value.
///
/// This function is separate, thus `nextGreater` keeps the shape that you can
/// copy into a solution. The run below checks that the two functions agree. It
/// does not assume that they do. The last row also shows the result at the
/// end: each index on the stack at that time never found a greater value.
fn traceNextGreater(out: *std.Io.Writer, gpa: Allocator, items: []const i32) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);

    try out.writeAll("   i  val  resolved (index -> answer)   stack after (bottom to top)\n");
    for (items, 0..) |value, i| {
        var popped: [16]usize = undefined;
        var count: usize = 0;
        while (stack.last()) |top| {
            if (items[top] >= value) break;
            popped[count] = top;
            count += 1;
            _ = stack.pop();
        }
        try stack.append(gpa, i);

        try writeCell(out, @intCast(i), 4);
        try writeCell(out, value, 5);
        try out.writeAll("  ");
        try writeResolved(out, popped[0..count], value, 28);
        try writeStack(out, items, stack.items);
        try out.writeByte('\n');
    }

    try out.print("  {d} indices never popped: ", .{stack.items.len});
    try writeStack(out, items, stack.items);
    try out.writeByte('\n');
}

/// One row of the cost table: the cost of the scan and the cost of the stack.
///
/// The two methods use the same array. Thus you can compare the two numbers,
/// because they do not come from different runs. The count for the scan is
/// comparisons, and the count for the stack is moves. No array can make the
/// stack moves more than `2n`.
fn writeCostRow(out: *std.Io.Writer, gpa: Allocator, name: []const u8, items: []const i32) !void {
    var storage: [64]?usize = undefined;
    const answers = storage[0..items.len];

    var comparisons: usize = 0;
    scanRight(items, answers, &comparisons);

    var work: Work = .{};
    try nextGreater(gpa, items, answers, &work);

    try out.print("  {s: <12}", .{name});
    try out.print("{d:>3}{d:>7}{d:>8}{d:>6}\n", .{
        items.len,
        comparisons,
        work.pushes,
        work.pops,
    });
}

/// An answers table: the value at each index and the position of its answer.
fn writeAnswers(
    out: *std.Io.Writer,
    items: []const i32,
    answers: []const ?usize,
    heading: []const u8,
) !void {
    try out.print("  idx  val  {s}   at\n", .{heading});
    for (items, 0..) |value, i| {
        try writeCell(out, @intCast(i), 5);
        try writeCell(out, value, 5);
        const at = answers[i];
        try writeMaybe(out, if (at) |a| items[a] else null, 14);
        try writeMaybe(out, if (at) |a| @as(i32, @intCast(a)) else null, 5);
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;
    const gpa = init.gpa;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);

    try out.print("{d} values parsed from the input\n", .{values.len});
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // The pass, with a trace. Each pop resolves an index. On each row, the
    // values on the stack become smaller from bottom to top.
    try out.writeAll("next greater to the right, one pass with a stack\n");
    try traceNextGreater(out, gpa, values);

    var stack_answers: [64]?usize = undefined;
    var scan_answers: [64]?usize = undefined;
    var work: Work = .{};
    try nextGreater(gpa, values, stack_answers[0..values.len], &work);
    try out.print(
        "  {d} pushes, {d} pops over {d} values, ceiling 2n = {d}\n\n",
        .{ work.pushes, work.pops, values.len, 2 * values.len },
    );

    // The answers, and the scan that they must agree with.
    var comparisons: usize = 0;
    scanRight(values, scan_answers[0..values.len], &comparisons);
    try out.writeAll("the answers, and the scan they have to agree with\n");
    try writeAnswers(out, values, stack_answers[0..values.len], "next greater");
    try out.print(
        "  stack and scan agree -> {}\n\n",
        .{std.mem.eql(?usize, stack_answers[0..values.len], scan_answers[0..values.len])},
    );

    // The rates, not the totals. Eleven values are not sufficient to show the
    // cost of the scan. Thus the program also uses the two arrays at the two
    // limits.
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n  scans  pushes  pops\n");
    try writeCostRow(out, gpa, "the input", values);
    try writeCostRow(out, gpa, "decreasing", &decreasing);
    try writeCostRow(out, gpa, "increasing", &increasing);
    try out.writeAll("\n");

    // The same stack with the opposite comparison. The answer comes from the
    // index that stays on the stack, not from the popped indices.
    try out.writeAll("previous smaller to the left, from the same stack\n");
    var left_answers: [64]?usize = undefined;
    var left_work: Work = .{};
    try previousSmaller(gpa, values, left_answers[0..values.len], &left_work);
    try writeAnswers(out, values, left_answers[0..values.len], "prev smaller");
    try out.print(
        "  {d} pushes, {d} pops, same ceiling\n",
        .{ left_work.pushes, left_work.pops },
    );

    try out.flush();
}
