//! title: The Monotonic Deque
//! The largest value in every window of width k, from one pass. Indices sit in
//! a deque in decreasing order of value. The back end drops an index for what
//! it holds. The front end drops one for where it is. The program prints both
//! ends working on every step, the departures with the reason each one left,
//! and the counters behind the amortised argument, so the tables in the
//! chapter are the tables CI ran.

const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. One line of values and a window width is the whole problem, and the
/// parser below reads the line the way it would read a real file.
const input =
    \\5 3 8 2 7 1 1 9 4 6 2 3
;

/// The window width the trace uses.
const width = 4;

/// Twelve values falling from left to right.
///
/// The maximum sits at the left edge of every window, so it leaves on every
/// slide and the repair-by-rescanning version pays full price each time. The
/// deque never evicts from the back on this array.
const falling = [_]i32{ 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };

/// The mirror of it. The maximum is the value that just arrived, so the repair
/// never fires, and the deque throws away everything it holds on every step.
const rising = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

/// A larger array, so the two rates are far enough apart to read.
const scale_n = 1000;
const scale_k = 100;

var scale_values: [scale_n]i32 = undefined;
var scale_out: [scale_n]i32 = undefined;
var scale_slots: [scale_n]usize = undefined;

/// Fill `buf` with values from a linear congruential generator.
///
/// Fixed seed, fixed constants, so the counts printed at the bottom are the
/// same on every machine and CI can diff them.
fn fillPseudoRandom(buf: []i32) void {
    var state: u32 = 20260909;
    for (buf) |*value| {
        state = state *% 1664525 +% 1013904223;
        value.* = @intCast((state >> 16) % 1000);
    }
}

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

/// A double-ended queue of indices over a fixed array.
///
/// `head` and `tail` only ever move right, and there is no wraparound. That is
/// safe because an index is pushed at most once for the whole run, so `tail`
/// cannot pass the number of values. Sizing `slots` at `items.len` is
/// therefore enough for any window width, and a ring buffer would only recycle
/// slots that are never asked for again.
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

/// What one run cost, split by which end did the work.
///
/// The two pop counters are kept apart because they answer different
/// questions. Their sum can never pass the pushes, and the pushes can never
/// pass the number of values.
const Work = struct {
    pushes: usize = 0,
    back_pops: usize = 0,
    front_pops: usize = 0,

    fn moves(w: Work) usize {
        return w.pushes + w.back_pops + w.front_pops;
    }
};

/// The largest value in every window of `k` consecutive values, in one pass.
///
/// The deque holds indices, and the values at those indices fall from front to
/// back. Two rules keep it that way, and neither one knows about the other.
///
/// The back evicts on value. An index already in the deque holding a value
/// smaller than the arriving one is finished: the arriving value is larger and
/// it stays in the window longer, so the smaller value can never be the answer
/// again. Dropping it is not an optimisation, it is the removal of an index
/// that no future window can want.
///
/// The front expires on index. `start` is the leftmost index the window now
/// covers, and anything below it is out of range whatever it holds. The
/// comparison here is between indices and never touches a value.
///
/// After both rules have run, the front holds the largest value in the window,
/// because everything larger was popped for being out of range and everything
/// in range that is smaller was popped from the back.
///
/// `>=` and not `>` on the back rule. Two equal values are both kept, since
/// the later one outlives the earlier and the earlier is still the answer
/// until it expires. Using `>` would drop the earlier one and give the same
/// maxima with a shorter deque.
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

/// The same answers by looking at every window from scratch.
///
/// `comparisons` counts the values read, which comes to `k` for each of the
/// `n - k + 1` windows however the values are arranged.
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

/// One value carried across the slides, and nothing else.
///
/// This is what a running total does for a sum, applied to a maximum. It takes
/// the arriving value into account and has no way to take the leaving one out,
/// so `best` is the largest value seen so far rather than the largest value in
/// the window. The rows where those differ are printed rather than described.
fn carryMax(items: []const i32, k: usize, out: []i32) void {
    var best = items[0];
    for (items, 0..) |value, i| {
        if (value > best) best = value;
        if (i + 1 >= k) out[i + 1 - k] = best;
    }
}

/// The repair: carry one value, and rescan the window whenever it leaves.
///
/// Correct on every array, and the price depends on the data. When the leaving
/// value is not the maximum, one comparison against the arriving value is
/// enough. When it is the maximum, nothing is left to fall back on and the
/// window has to be read again.
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

/// One index leaving the deque, with the end it left by.
const Departure = struct {
    index: usize,
    from_back: bool,
    step: usize,
    /// The arriving value for a back eviction, the window start for a front
    /// expiry. The two rules read different things, so the record does too.
    against: usize,
};

/// Right-align a value in a cell of `field` characters.
///
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i32, field: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', field - text.len);
    try out.writeAll(text);
}

/// A list of indices as `index:value` pairs, padded out to `field`.
///
/// Printing the value beside the index is what makes the ordering visible. A
/// column of bare indices would hide the one property the method rests on.
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

/// `dequeMax` with a row printed per arriving value, and the departures kept.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two agree rather than trusting it.
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

/// Every index that left, in the order it left, with the reason.
///
/// The two reason columns are the point of the table. A back row quotes two
/// values and no index; a front row quotes two indices and no value.
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

/// The windows, their values, the rescanned answer and the carried one.
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

    // Every window read from scratch, beside one value carried across the
    // slides. The second column is wrong wherever the value that left was the
    // one being carried.
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

    // The repair. Correct everywhere, and priced by the data.
    var repaired_answers: [64]i32 = undefined;
    var repaired: usize = 0;
    rescanOnLoss(values, k, &repaired_answers, &repaired);
    try out.print(
        "rescanning only when the maximum leaves: {d} comparisons, agrees -> {}\n\n",
        .{ repaired, std.mem.eql(i32, repaired_answers[0..windows], scanned_answers[0..windows]) },
    );

    // The pass, printed. Both ends work on the last row.
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

    // Three shapes of data and one larger array. The repair column swings by a
    // factor of three; the push column is the length of the array every time.
    fillPseudoRandom(&scale_values);
    try out.writeAll("what each array costs\n");
    try out.writeAll("  array         n   k  rescan  on loss  pushes  back  front\n");
    try writeCostRow(out, "the input", values, k, &scanned_answers, &slots);
    try writeCostRow(out, "falling", &falling, k, &scanned_answers, &slots);
    try writeCostRow(out, "rising", &rising, k, &scanned_answers, &slots);
    try writeCostRow(out, "random", &scale_values, scale_k, &scale_out, &scale_slots);

    try out.flush();
}
