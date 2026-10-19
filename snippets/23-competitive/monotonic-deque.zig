//! title: The Monotonic Deque
//! The largest value in each window of width k, in one pass. A deque holds
//! indices in descending order of value. The back end removes an index because
//! of its value, and the front end removes an index because of its position. The
//! program prints the work at the two ends at each step. It also prints each
//! index that left with the reason, and the counters for the amortised
//! argument. Thus the tables in the chapter are the tables that CI ran.

const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The full problem is one line of values and a window width. The parser
/// below reads the line in the same way that it reads a real file.
const input =
    \\5 3 8 2 7 1 1 9 4 6 2 3
;

/// The window width the trace uses.
const width = 4;

/// Twelve values that decrease from left to right.
///
/// The maximum is at the left edge of each window. Thus the maximum leaves at
/// each slide, and the version that repairs with a new scan scans the window
/// each time. On this array, the deque never removes an index from the back.
const falling = [_]i32{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The opposite of `falling`. The maximum is the value that arrived last. Thus
/// the repair never occurs, and at each step the deque removes all that it holds.
const rising = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

/// A larger array. Thus the difference between the two rates is easy to see.
const scale_n = 1000;
const scale_k = 100;

var scale_values: [scale_n]i32 = undefined;
var scale_out: [scale_n]i32 = undefined;
var scale_slots: [scale_n]usize = undefined;

/// Fill `buf` with values from a linear congruential generator.
///
/// The seed and the constants do not change. Thus the counts at the bottom are
/// the same on each machine, and CI can compare them.
fn fillPseudoRandom(buf: []i32) void {
    var state: u32 = 20260909;
    for (buf) |*value| {
        state = state *% 1664525 +% 1013904223;
        value.* = @intCast((state >> 16) % 1000);
    }
}

/// Read one line of whitespace-separated integers into `out`.
///
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. On a judge, give the
/// function a reader for stdin. The function does not change.
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

/// A double-ended queue of indices over a fixed array.
///
/// `head` and `tail` move only to the right, and they do not wrap around. This
/// is safe because the run pushes each index one time or less. Thus `tail`
/// cannot go past the number of values. Thus `items.len` slots are sufficient
/// for each window width. A ring buffer only lets the deque use old slots
/// again, and the algorithm never needs those slots again.
const Deque = struct {
    slots: []usize,
    head: usize = 0,
    tail: usize = 0,

    fn isEmpty(d: Deque) bool {
        return d.head == d.tail;
    }

    fn indices(d: Deque) []const usize {
        return d.slots[d.head..d.tail];
    }

    fn front(d: Deque) ?usize {
        if (d.isEmpty()) return null;
        return d.slots[d.head];
    }

    fn back(d: Deque) ?usize {
        if (d.isEmpty()) return null;
        return d.slots[d.tail - 1];
    }

    fn pushBack(d: *Deque, index: usize) void {
        std.debug.assert(d.tail < d.slots.len);
        d.slots[d.tail] = index;
        d.tail += 1;
    }

    fn popBack(d: *Deque) void {
        d.tail -= 1;
    }

    fn popFront(d: *Deque) void {
        d.head += 1;
    }
};

/// The cost of one run, for each end of the deque.
///
/// The two pop counters are separate because they answer different questions.
/// Their sum can never be more than the pushes. The pushes can never be more
/// than the number of values.
const Work = struct {
    pushes: usize = 0,
    back_pops: usize = 0,
    front_pops: usize = 0,

    fn moves(w: Work) usize {
        return w.pushes + w.back_pops + w.front_pops;
    }
};

/// The largest value in each window of `k` consecutive values, in one pass.
///
/// The deque holds indices. From front to back, the values at those indices
/// decrease. Two rules keep this order, and each rule is independent of the
/// other rule.
///
/// The back removes by value. Look at an index in the deque with a value that
/// is smaller than the value that arrives. The new value is larger, and it
/// stays in the window longer. Thus the smaller value can never be the answer
/// again. The removal is safe, because no future window can need that index.
///
/// The front removes by index. `start` is the leftmost index in the window
/// now. Each index below `start` is out of range, whatever its value is. This
/// comparison is between indices, and it never reads a value.
///
/// After the two rules, the front holds the largest value in the window. Each
/// larger value left because it was out of range. Each smaller value in range
/// left from the back.
///
/// Use `>=`, not `>`, in the back rule. The deque keeps two equal values,
/// because the later value stays longer, and the earlier value is the answer
/// until it expires. With `>`, the deque removes the earlier value. The maxima
/// are the same, and the deque is shorter.
fn dequeMax(items: []const i32, k: usize, out: []i32, slots: []usize, work: *Work) void {
    var d: Deque = .{ .slots = slots };

    for (items, 0..) |value, i| {
        while (d.back()) |b| {
            if (items[b] >= value) break;
            d.popBack();
            work.back_pops += 1;
        }
        d.pushBack(i);
        work.pushes += 1;

        if (i + 1 < k) continue;
        const start = i + 1 - k;
        while (d.front()) |f| {
            if (f >= start) break;
            d.popFront();
            work.front_pops += 1;
        }
        out[start] = items[d.front().?];
    }
}

/// The same answers, from a new scan of each window.
///
/// `comparisons` counts the values that the function reads. The count is `k`
/// for each of the `n - k + 1` windows, whatever the order of the values.
fn rescanMax(items: []const i32, k: usize, out: []i32, comparisons: *usize) void {
    var start: usize = 0;
    while (start + k <= items.len) : (start += 1) {
        var best = items[start];
        comparisons.* += 1;
        for (items[start + 1 .. start + k]) |value| {
            comparisons.* += 1;
            if (value > best) best = value;
        }
        out[start] = best;
    }
}

/// One value that moves with the window, and nothing more.
///
/// For a sum, you can add the value that arrives and subtract the value that
/// leaves. This function tries the same method for a maximum. It includes the
/// value that arrives, but it cannot remove the value that leaves.
/// Thus `best` is the largest value until now, not the largest value in the
/// window. The program prints the rows where the two values are different.
fn carryMax(items: []const i32, k: usize, out: []i32) void {
    var best = items[0];
    for (items, 0..) |value, i| {
        if (value > best) best = value;
        if (i + 1 >= k) out[i + 1 - k] = best;
    }
}

/// The repair: carry one value, and scan the window again when that value
/// leaves.
///
/// The function is correct on each array, and the cost depends on the data.
/// If the value that leaves is not the maximum, one comparison with the value
/// that arrives is sufficient. If the value that leaves is the maximum, no
/// other information is available. Then the function must read the window again.
fn rescanOnLoss(items: []const i32, k: usize, out: []i32, comparisons: *usize) void {
    var best = items[0];
    comparisons.* += 1;
    for (items[1..k]) |value| {
        comparisons.* += 1;
        if (value > best) best = value;
    }
    out[0] = best;

    var start: usize = 1;
    while (start + k <= items.len) : (start += 1) {
        if (items[start - 1] == best) {
            best = items[start];
            comparisons.* += 1;
            for (items[start + 1 .. start + k]) |value| {
                comparisons.* += 1;
                if (value > best) best = value;
            }
        } else {
            comparisons.* += 1;
            const arriving = items[start + k - 1];
            if (arriving > best) best = arriving;
        }
        out[start] = best;
    }
}

/// One index that left the deque, and the end that it left from.
const Departure = struct {
    index: usize,
    from_back: bool,
    step: usize,
    /// For a removal at the back, the value that arrived. For an expiry at the
    /// front, the start of the window. The two rules read different data, thus
    /// the record does too.
    against: usize,
};

/// Right-align a value in a cell of `field` characters.
///
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the columns are easy to read.
fn writeCell(out: *std.Io.Writer, value: i32, field: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', field - text.len);
    try out.writeAll(text);
}

/// A list of indices as `index:value` pairs, with padding to `field`.
///
/// The value next to the index makes the order visible. A column of only
/// indices hides the property that the method needs.
fn writePairs(
    out: *std.Io.Writer,
    items: []const i32,
    list: []const usize,
    sep: []const u8,
    field: usize,
) !void {
    var used: usize = 0;
    if (list.len == 0) {
        try out.writeByte('.');
        used = 1;
    }
    for (list, 0..) |idx, n| {
        if (n > 0) {
            try out.writeAll(sep);
            used += sep.len;
        }
        var digits: [24]u8 = undefined;
        const text = try std.mem.print(&digits, "{d}:{d}", .{ idx, items[idx] });
        try out.writeAll(text);
        used += text.len;
    }
    if (field > used) try out.splatByteAll(' ', field - used);
}

/// `dequeMax`, but it prints a row for each value that arrives, and it records
/// each index that leaves.
///
/// This function is separate, thus `dequeMax` keeps the shape that you can copy
/// into a solution. The run below checks that the two functions agree. It does
/// not assume that they do.
fn traceDequeMax(
    out: *std.Io.Writer,
    items: []const i32,
    k: usize,
    slots: []usize,
    gone: []Departure,
) !usize {
    var d: Deque = .{ .slots = slots };
    var count: usize = 0;

    try out.writeAll("   i  val  evicted from back     expired  deque, front to back      max\n");
    for (items, 0..) |value, i| {
        var evicted: [16]usize = undefined;
        var evicted_len: usize = 0;
        while (d.back()) |b| {
            if (items[b] >= value) break;
            evicted[evicted_len] = b;
            evicted_len += 1;
            gone[count] = .{ .index = b, .from_back = true, .step = i, .against = i };
            count += 1;
            d.popBack();
        }
        d.pushBack(i);

        var expired: [16]usize = undefined;
        var expired_len: usize = 0;
        var answer: ?i32 = null;
        if (i + 1 >= k) {
            const start = i + 1 - k;
            while (d.front()) |f| {
                if (f >= start) break;
                expired[expired_len] = f;
                expired_len += 1;
                gone[count] = .{ .index = f, .from_back = false, .step = i, .against = start };
                count += 1;
                d.popFront();
            }
            answer = items[d.front().?];
        }

        try writeCell(out, @intCast(i), 4);
        try writeCell(out, value, 5);
        try out.writeAll("  ");
        try writePairs(out, items, evicted[0..evicted_len], ", ", 22);
        try writePairs(out, items, expired[0..expired_len], ", ", 9);
        try writePairs(out, items, d.indices(), " ", 24);
        if (answer) |a| try writeCell(out, a, 5) else try out.writeAll("    .");
        try out.writeByte('\n');
    }

    try out.writeAll("  left in the deque: ");
    try writePairs(out, items, d.indices(), " ", 0);
    try out.writeByte('\n');
    return count;
}

/// Each index that left, in the order that it left, with the reason.
///
/// The two reason columns show the difference between the rules. A back row
/// shows two values and no index. A front row shows two indices and no value.
fn writeDepartures(
    out: *std.Io.Writer,
    items: []const i32,
    gone: []const Departure,
) !void {
    try out.writeAll("  index  value  left by  because\n");
    for (gone) |g| {
        try writeCell(out, @intCast(g.index), 7);
        try writeCell(out, items[g.index], 7);
        try out.writeAll("  ");
        if (g.from_back) {
            try out.writeAll("back     ");
            try out.print("{d} < {d}, the value arriving at i={d}\n", .{
                items[g.index],
                items[g.against],
                g.step,
            });
        } else {
            try out.writeAll("front    ");
            try out.print("index {d} is below window start {d} at i={d}\n", .{
                g.index,
                g.against,
                g.step,
            });
        }
    }
}

/// The windows, their values, the answer from a new scan and the carried answer.
fn writeWindows(
    out: *std.Io.Writer,
    items: []const i32,
    k: usize,
    scanned: []const i32,
    carried: []const i32,
) !usize {
    var wrong: usize = 0;
    try out.writeAll("  window       values        rescan  carried\n");
    var start: usize = 0;
    while (start + k <= items.len) : (start += 1) {
        try out.print("  [{d:>2}..{d:>2})", .{ start, start + k });
        for (items[start .. start + k]) |value| try writeCell(out, value, 4);
        try writeCell(out, scanned[start], 9);
        try writeCell(out, carried[start], 9);
        if (carried[start] != scanned[start]) {
            try out.writeAll("  wrong");
            wrong += 1;
        }
        try out.writeByte('\n');
    }
    return wrong;
}

/// One row of the cost table: three methods over the same array and width.
fn writeCostRow(
    out: *std.Io.Writer,
    name: []const u8,
    items: []const i32,
    k: usize,
    answers: []i32,
    slots: []usize,
) !void {
    var scanned: usize = 0;
    rescanMax(items, k, answers, &scanned);

    var repaired: usize = 0;
    rescanOnLoss(items, k, answers, &repaired);

    var work: Work = .{};
    dequeMax(items, k, answers, slots, &work);

    try out.print("  {s: <10}{d:>5}{d:>4}{d:>8}{d:>9}{d:>8}{d:>6}{d:>7}\n", .{
        name,
        items.len,
        k,
        scanned,
        repaired,
        work.pushes,
        work.back_pops,
        work.front_pops,
    });
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var value_storage: [64]i32 = undefined;
    const values = try readRow(&reader, &value_storage);
    const k = width;
    const windows = values.len - k + 1;

    try out.print(
        "{d} values parsed from the input, window width {d}, {d} windows\n",
        .{ values.len, k, windows },
    );
    try out.writeAll("  idx ");
    for (0..values.len) |i| try out.print("{d:>4}", .{i});
    try out.writeAll("\n  val ");
    for (values) |v| try writeCell(out, v, 4);
    try out.writeAll("\n\n");

    // A new scan of each window, next to one value that moves with the window.
    // The second column is wrong at each row where the value that left was the
    // carried value.
    var scanned_answers: [64]i32 = undefined;
    var carried_answers: [64]i32 = undefined;
    var scanned: usize = 0;
    rescanMax(values, k, &scanned_answers, &scanned);
    carryMax(values, k, &carried_answers);

    try out.writeAll("every window read from scratch, against one carried maximum\n");
    const wrong = try writeWindows(out, values, k, &scanned_answers, &carried_answers);
    try out.print(
        "  {d} comparisons to rescan, {d} of {d} windows carried wrong\n\n",
        .{ scanned, wrong, windows },
    );

    // The repair. It is correct on each array, and its cost depends on the data.
    var repaired_answers: [64]i32 = undefined;
    var repaired: usize = 0;
    rescanOnLoss(values, k, &repaired_answers, &repaired);
    try out.print(
        "rescanning only when the maximum leaves: {d} comparisons, agrees -> {}\n\n",
        .{ repaired, std.mem.eql(i32, repaired_answers[0..windows], scanned_answers[0..windows]) },
    );

    // The pass, with a trace. On the last row, the two ends both remove an index.
    var slots: [64]usize = undefined;
    var gone: [64]Departure = undefined;
    try out.writeAll("the deque, one row per arriving value\n");
    const gone_len = try traceDequeMax(out, values, k, &slots, &gone);
    try out.writeByte('\n');

    try out.writeAll("every index that left the deque, in the order it left\n");
    try writeDepartures(out, values, gone[0..gone_len]);
    try out.writeByte('\n');

    var deque_answers: [64]i32 = undefined;
    var work: Work = .{};
    dequeMax(values, k, &deque_answers, &slots, &work);
    try out.print(
        "deque and rescan agree -> {}\n",
        .{std.mem.eql(i32, deque_answers[0..windows], scanned_answers[0..windows])},
    );
    try out.print(
        "  {d} pushes, {d} popped from the back, {d} from the front, {d} left over\n",
        .{
            work.pushes,
            work.back_pops,
            work.front_pops,
            work.pushes - work.back_pops - work.front_pops,
        },
    );
    try out.print(
        "  {d} moves over {d} values, ceiling 2n = {d}\n\n",
        .{ work.moves(), values.len, 2 * values.len },
    );

    // Three shapes of data and one larger array. The repair column changes by
    // a factor of three. The push column is always the length of the array.
    fillPseudoRandom(&scale_values);
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n   k  rescan  on loss  pushes  back  front\n");
    try writeCostRow(out, "the input", values, k, &scanned_answers, &slots);
    try writeCostRow(out, "falling", &falling, k, &scanned_answers, &slots);
    try writeCostRow(out, "rising", &rising, k, &scanned_answers, &slots);
    try writeCostRow(out, "random", &scale_values, scale_k, &scale_out, &scale_slots);

    try out.flush();
}
