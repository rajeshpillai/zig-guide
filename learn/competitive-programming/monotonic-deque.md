# The Monotonic Deque

> The largest value in each window, from a deque with two ends that remove indices for two different reasons.

A window moves across an array one step at a time. At each step, one value enters from the right and one value leaves from the left. The problem is to find the largest value in each window.

There are three cases:

- If the previous maximum is still inside the new window, the answer can stay the same.
- If the new value is larger, the new value becomes the new maximum.
- If the old maximum is the value that left, the answer is not known. This case is difficult.

A monotonic deque solves the problem in one pass.

The example below uses twelve values and a window size of four. Thus there are nine windows. The program prints the changes at the two ends of the deque at each step.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.monotonic-deque`)*

## Do not carry only the maximum

A sliding sum is easy to update, because you can add the value that enters and subtract the value that leaves. A maximum does not work in the same way.

If the largest value leaves the window, one stored number cannot give the next largest value. The stored number does not hold sufficient information.

```zig
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
```

*Quoted from the source: `carryMax` from `snippets/23-competitive/monotonic-deque.zig`.*

One correct solution is to scan each window again from the start. The cost is `k` comparisons for each window.

A different method keeps the previous maximum and compares it with the new value. This method is faster, but it gives the wrong answer when the previous maximum leaves the window.

The two methods on the example input:

```
  window       values        rescan  carried
  [ 0.. 4)   5   3   8   2        8        8
  [ 1.. 5)   3   8   2   7        8        8
  [ 2.. 6)   8   2   7   1        8        8
  [ 3.. 7)   2   7   1   1        7        8  wrong
  [ 4.. 8)   7   1   1   9        9        9
  [ 5.. 9)   1   1   9   4        9        9
  [ 6..10)   1   9   4   6        9        9
  [ 7..11)   9   4   6   2        9        9
  [ 8..12)   4   6   2   3        6        9  wrong
  36 comparisons to rescan, 2 of 9 windows carried wrong
```

The value 8 at index 2 is the maximum for the first three windows. When the value 8 leaves, the carried value is still 8, but 8 is not inside the window. Later, the same problem occurs with 9.

## Scan again only when the maximum leaves

```zig
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
```

*Quoted from the source: `rescanOnLoss` from `snippets/23-competitive/monotonic-deque.zig`.*

The previous method can be better. When the window moves, compare the value that leaves with the current maximum:

- If the two values are different, the maximum is still inside the window. Compare only the value that enters with the maximum.
- If the value that leaves is the current maximum, the next largest value is not known. Scan the new window again.

For this input:

```
rescanning only when the maximum leaves: 18 comparisons, agrees -> true
```

On this array, the method is correct and costs much less than a scan of each window. But the method can still be slow on a different input. If the maximum leaves at each slide, the method scans almost each window again. A monotonic deque does not have this problem.

## Keep useful indices in descending order

```zig
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
```

*Quoted from the source: `dequeMax` from `snippets/23-competitive/monotonic-deque.zig`.*

The deque holds indices, not values. From front to back, the values at those indices are in descending order. The front always points to the largest useful value in the current window.

Two rules keep the deque correct:

- When a new value arrives, the back removes indices with smaller values.
- When the window moves, the front removes indices that are now outside the window.

Each row below shows one value that arrives. The row also shows these items:

- The indices that the back removed.
- The indices that expired from the front.
- The deque after the step.
- The current maximum.

```
   i  val  evicted from back     expired  deque, front to back      max
   0    5  .                     .        0:5                         .
   1    3  .                     .        0:5 1:3                     .
   2    8  1:3, 0:5              .        2:8                         .
   3    2  .                     .        2:8 3:2                     8
   4    7  3:2                   .        2:8 4:7                     8
   5    1  .                     .        2:8 4:7 5:1                 8
   6    1  .                     2:8      4:7 5:1 6:1                 7
   7    9  6:1, 5:1, 4:7         .        7:9                         9
   8    4  .                     .        7:9 8:4                     9
   9    6  8:4                   .        7:9 9:6                     9
  10    2  .                     .        7:9 9:6 10:2                9
  11    3  10:2                  7:9      9:6 11:3                    6
```

At index 2, the value 8 arrives. The back of the deque holds index 1 with value 3. The value 8 is larger than 3. Thus, while 8 is in the same window, index 1 can never become a future maximum. The back removes index 1.

The next value at the back is 5, and 5 is also smaller than 8. The back removes that index too. Then the deque adds index 2. Now the deque holds only `2:8`.

At index 7, the value 9 arrives. The back removes the values 1, 1 and 7, because all three values are smaller than 9.

At index 11, the two ends of the deque both remove an index. The new value 3 removes index 10, which holds 2. Then index 7 expires from the front, because index 7 is outside the current window. Index 7 holds 9. After index 7 leaves, the next index at the front is 9, with the value 6. Thus the maximum becomes 6.

The maximum is always available directly from the front, as `items[d.front().?]`. You do not have to search the deque.

The deque keeps equal values, because the back rule removes only values that are strictly smaller. Thus, if two equal maximum values exist, the older value can expire while the newer value stays available.

The figure plays the deque trace, one step for each new value. The outline is the window. Under it, the deque holds the candidates, and the front is the maximum.

*Figure: 12 values and a window of 4 that moves right. A deque under them keeps the candidates for the maximum, and its front is the answer. The deque trace from the program above, one step for each new value.*

## Remove by value at the back

The back rule answers one question: after the new value arrives, can an old value ever become the maximum again?

Look at an entry in the deque with a value that is smaller than the new value. The new value is larger, and it is also further to the right. Thus the new value stays inside future windows for at least as long as the older, smaller value.

Each future window that holds the older value also holds the newer value. The newer value is larger, thus the older value can never become the maximum. The back can remove the older index permanently.

## Remove by position at the front

The front rule solves a different problem. The current window starts at index `start`. Each stored index that is smaller than `start` is outside the window. The front must remove that index, whatever its value is.

This rule compares only indices. Values have no part in the rule.

For example, index 7 holds 9, the largest value in the full array. At the last step, index 7 must still leave, because the window starts at index 8.

The two rules together keep the maximum of the current window at the front.

The program also prints each index that leaves the deque:

```
every index that left the deque, in the order it left
  index  value  left by  because
      1      3  back     3 < 8, the value arriving at i=2
      0      5  back     5 < 8, the value arriving at i=2
      3      2  back     2 < 7, the value arriving at i=4
      2      8  front    index 2 is below window start 3 at i=6
      6      1  back     1 < 9, the value arriving at i=7
      5      1  back     1 < 9, the value arriving at i=7
      4      7  back     7 < 9, the value arriving at i=7
      8      4  back     4 < 6, the value arriving at i=9
     10      2  back     2 < 3, the value arriving at i=11
      7      9  front    index 7 is below window start 8 at i=11
```

The two kinds of row have two different causes:

- A row with `back` shows an index that left because a larger value arrived.
- A row with `front` shows an index that left because it moved outside the window.

[The monotonic stack](https://www.ziglang.in/learn/competitive-programming/monotonic-stack/) needs only one end, because its entries never expire from a window that moves.

A normal queue of the last `k` indices knows which indices expire. But the queue keeps values that can no longer become the maximum. The monotonic deque removes the two kinds of index.

## Why the algorithm is O(n)

The two `while` loops inside the `for` loop are still linear. The reason is the same as in [the monotonic stack](https://www.ziglang.in/learn/competitive-programming/monotonic-stack/).

The algorithm pushes each index one time and removes each index one time or less. Thus there are at most about `2n` deque operations.

For this input:

```
deque and rescan agree -> true
  12 pushes, 8 popped from the back, 2 from the front, 2 left over
  22 moves over 12 values, ceiling 2n = 24
```

The algorithm pushes twelve indices. Eight indices leave from the back and two leave from the front. Two indices stay in the deque when the algorithm stops. The sum of those numbers is twelve indices.

[Sliding Window](https://www.ziglang.in/learn/competitive-programming/sliding-window/) uses the same kind of amortised argument.

## Make the deque

```zig
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
```

*Quoted from the source: `Deque` from `snippets/23-competitive/monotonic-deque.zig`.*

The deque uses a plain array and two indices. The indices do not wrap around to the start of the array. This design is sufficient for this algorithm, because the algorithm pushes each input index only one time.

`tail` moves forward one slot for each push. Thus an array with `n` slots can hold each index that the algorithm will insert. After `tail` moves past a slot, the algorithm never inserts that index again.

A ring buffer lets the deque use old storage positions again, but this algorithm does not need that.

## Compare the methods

The program compares three methods:

- Scan each window again.
- Carry the maximum, and scan again only when the maximum leaves.
- Use a monotonic deque.

```
what each array costs
  array         n   k  rescan  on loss  pushes  back  front
  the input    12   4      36       18      12     8      2
  falling      12   4      36       36      12     0      8
  rising       12   4      36       12      12    11      0
  random     1000 100   90100     1990    1000   983     10
```

For the example input, a new scan of each window needs 36 comparisons. A new scan only when the maximum leaves needs 18. The deque does a linear number of pushes and pops.

The "falling" array shows the weak point of the second method. In an array with values that decrease, the maximum is always at the left side of the window. Thus the maximum leaves at each slide, and the method must scan the full window each time. The cost becomes the same as a scan of each window.

The "rising" array is different. Each new value becomes the maximum, thus the second method costs very little. The deque removes almost all of its indices from the back at each step, but the deque can remove each index only one time.

The last row shows the difference more clearly. For 1,000 values and a window size of 100:

```
rescan       90,100 reads
on loss       1,990 reads
deque         1,000 pushes and 993 pops
```

The cost of the first two methods depends very much on the shape of the input. The total work of the deque stays O(n) for each input.

## Use the same pattern again

If you reverse the comparison at the back, the same structure gives the minimum value in each window:

- For the maximum, remove smaller values from the back.
- For the minimum, remove larger values from the back.

You can also keep two deques at the same time. One deque tracks the maximum, and the other deque tracks the minimum. Then, after the deque updates, each window gives the two values in O(1).

This method is useful for problems about the difference between the largest and the smallest value in each window.
