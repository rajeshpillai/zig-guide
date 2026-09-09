//! title: The Monotonic Stack
//! A stack of indices held in decreasing order of value, so that one pass
//! answers a question that looks like it needs a scan from every index. The
//! program prints the push, the pops and the stack after every step, plus the
//! counters behind the amortised argument, so the trace in the chapter is the
//! trace CI ran.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. One line of values is all the problem needs, and the parser below
/// reads it the way it would read a real file.
const input =
    \\3 1 4 1 5 9 2 6 5 3 7
;

/// The worst array for a scan and the easiest one for the stack.
///
/// Nothing has a greater value to its right, so the scan walks to the end from
/// every index and the stack never pops.
const decreasing = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The mirror of it. The scan stops on its first comparison every time, and the
/// stack pops the index it pushed a moment ago.
const increasing = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };

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

/// The two counters the amortised argument rests on.
///
/// Counting them costs two lines and settles a question that reasoning about
/// the nested loop usually gets wrong.
const Work = struct {
    pushes: usize = 0,
    pops: usize = 0,
};

/// For each index, the index of the first greater value to its right.
///
/// The obvious solution. Fix an index, walk right until something beats it,
/// give up at the end of the array. `comparisons` counts the values looked at,
/// which is the number that grows with the square of the input.
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
/// The stack holds the indices whose answer is still unknown, and it holds them
/// in decreasing order of value. When `value` arrives, every index on the stack
/// with a smaller value has found its answer, and those indices sit together at
/// the top because of the ordering. Pop them, record `i`, push `i`.
///
/// The order is preserved by the loop itself. Everything left after the pops is
/// at least as large as `value`, so putting `i` on top keeps the stack falling
/// from bottom to top.
///
/// `>=` and not `>`. An equal value is not greater, so an index waiting on a 7
/// is not answered by another 7.
///
/// Indices still on the stack when the array runs out are never written, and
/// `out` was filled with null before the loop, so having no answer needs no
/// case of its own.
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

/// The first smaller value to the left, from the same machine.
///
/// Two changes. The comparison flips, so the stack rises from bottom to top
/// instead of falling. And the answer is read off the survivor rather than
/// written into the values popped: after the pops, whatever is still on top is
/// the nearest index to the left holding a smaller value.
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
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// A value that may be missing, right-aligned. A dot means no answer.
fn writeMaybe(out: *std.Io.Writer, value: ?i32, width: usize) !void {
    if (value) |v| return writeCell(out, v, width);
    try out.splatByteAll(' ', width - 1);
    try out.writeByte('.');
}

/// The stack, bottom to top, as `index:value` pairs.
///
/// Printing the values beside the indices is what makes the ordering visible.
/// A column of bare indices would hide the one property the whole method rests
/// on.
fn writeStack(out: *std.Io.Writer, items: []const i32, indices: []const usize) !void {
    for (indices, 0..) |idx, k| {
        if (k > 0) try out.writeByte(' ');
        try out.print("{d}:{d}", .{ idx, items[idx] });
    }
}

/// The indices resolved by this step, each with the answer it got.
///
/// They all get the same answer, since they were all popped by the same
/// arriving value. Writing it out per index keeps the row readable next to the
/// answers table further down.
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

/// `nextGreater` with a row printed per incoming value.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two agree rather than trusting it.
/// The last row is also the answer to what happens at the end: whatever the
/// stack is holding then never found a greater value.
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

/// One row of the cost table: what the scan pays against what the stack pays.
///
/// Both run over the same array, so the two numbers are comparable rather than
/// quoted from different runs. The scan's count is comparisons and the stack's
/// is moves, and neither array can push the stack past `2n`.
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

/// An answers table: the value at each index and where its answer lives.
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

    // The pass, printed. Every pop resolves an index, and the stack is
    // decreasing on every row.
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

    // The answers, and the scan they have to agree with.
    var comparisons: usize = 0;
    scanRight(values, scan_answers[0..values.len], &comparisons);
    try out.writeAll("the answers, and the scan they have to agree with\n");
    try writeAnswers(out, values, stack_answers[0..values.len], "next greater");
    try out.print(
        "  stack and scan agree -> {}\n\n",
        .{std.mem.eql(?usize, stack_answers[0..values.len], scan_answers[0..values.len])},
    );

    // The rates, not the totals. Eleven values is too few for the scan to look
    // bad, so the two arrays that bracket it are here too.
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n  scans  pushes  pops\n");
    try writeCostRow(out, gpa, "the input", values);
    try writeCostRow(out, gpa, "decreasing", &decreasing);
    try writeCostRow(out, gpa, "increasing", &increasing);
    try out.writeAll("\n");

    // The same stack, one comparison flipped and the answer read from the
    // survivor instead of the values popped.
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
