//! title: Merge Intervals
//! Sorting by start, then one pass that only ever compares an interval with
//! the run being built. The program prints the list before and after sorting,
//! a row per merge step, the same pass with the end taken from the wrong
//! place, and a sweep that counts how many intervals overlap at once. A
//! coordinate map built independently checks both answers.

const std = @import("std");

/// The intervals, as text, one per line: start then end.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. The order is the order they arrived in, which is to say no order at
/// all, and the parser below reads it the way it would read a real file.
///
/// `1 20` with `3 5` inside it is the case that catches a merge written
/// without `@max`. `3 5` next to `5 8`, and `24 26` next to `26 29`, are the
/// pairs that touch at a single coordinate.
const input =
    \\24 26
    \\1 20
    \\40 40
    \\33 36
    \\12 15
    \\5 8
    \\3 5
    \\4 7
    \\13 17
    \\18 21
    \\26 29
;

/// A closed interval: both `start` and `end` are inside it.
///
/// So `[3, 5]` and `[5, 8]` share the coordinate 5 and overlap. The other
/// convention, half-open, would write those as `[3, 5)` and `[5, 8)` and they
/// would not.
const Interval = struct {
    start: i32,
    end: i32,
};

/// The comparator `std.mem.sort` wants: true when `a` belongs before `b`.
///
/// Only the start decides which interval the pass sees first. Ordering equal
/// starts by end as well costs nothing and makes the printed table stable.
/// [Sorting](/learn/standard-library/sorting/) has the rest of `std.mem.sort`.
fn byStart(_: void, a: Interval, b: Interval) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

/// Read one interval per line into `out`.
///
/// Taking a `*std.Io.Reader` rather than the string is the same discipline the
/// networking chapters use for protocols. The function turns bytes into
/// values, so the same code works over a file, over a socket, and over a
/// string literal that CI can check.
fn readIntervals(reader: *std.Io.Reader, out: []Interval) ![]Interval {
    var count: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        if (count == out.len) return error.TooManyIntervals;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const start_text = fields.next() orelse return error.MissingStart;
        const end_text = fields.next() orelse return error.MissingEnd;
        const start = try std.fmt.parseInt(i32, start_text, 10);
        const end = try std.fmt.parseInt(i32, end_text, 10);
        if (end < start) return error.BackwardsInterval;
        out[count] = .{ .start = start, .end = end };
        count += 1;
    }
    return out[0..count];
}

/// Merge overlapping intervals. `sorted` must already be sorted by start.
///
/// Sorted, an interval can only overlap the run currently open. Anything
/// earlier ended before this run began, and anything later starts no earlier
/// than this one does, so there is nothing else to compare against.
///
/// `<=` and not `<`, because these intervals are closed and `[3, 5]` meets
/// `[5, 8]` at the coordinate 5.
///
/// `@max` and not `iv.end`. A nested interval like `[3, 5]` inside `[1, 20]`
/// has a smaller end, and taking it would shorten the run to five.
fn merge(sorted: []const Interval, out: []Interval) []Interval {
    var count: usize = 0;
    for (sorted) |iv| {
        if (count > 0 and iv.start <= out[count - 1].end) {
            out[count - 1].end = @max(out[count - 1].end, iv.end);
        } else {
            out[count] = iv;
            count += 1;
        }
    }
    return out[0..count];
}

/// The same pass with `@max` dropped, which is the shape people write first.
///
/// It reads as harmless: the intervals are sorted, so the next end should be
/// the larger one. That holds for every interval except the ones already
/// inside the run.
fn mergeTakingLast(sorted: []const Interval, out: []Interval) []Interval {
    var count: usize = 0;
    for (sorted) |iv| {
        if (count > 0 and iv.start <= out[count - 1].end) {
            out[count - 1].end = iv.end;
        } else {
            out[count] = iv;
            count += 1;
        }
    }
    return out[0..count];
}

/// One end of one interval, as an event on the coordinate line.
///
/// `delta` is +1 where an interval starts and -1 where it ends. `owner` is
/// only carried so the trace can name the interval.
const Event = struct {
    at: i32,
    delta: i32,
    owner: Interval,
};

/// Order events by coordinate, and put a start before an end at the same one.
///
/// The tie is the closed convention again. `[24, 26]` and `[26, 29]` both hold
/// the coordinate 26, so both are in use there and the count has to rise
/// before it falls.
fn startsFirst(_: void, a: Event, b: Event) bool {
    if (a.at != b.at) return a.at < b.at;
    return a.delta > b.delta;
}

/// The half-open reading: an end at the same coordinate is released first.
fn endsFirst(_: void, a: Event, b: Event) bool {
    if (a.at != b.at) return a.at < b.at;
    return a.delta < b.delta;
}

/// The most intervals in use at any one coordinate, and where that first
/// happens.
///
/// The running count is the answer. Nothing here merges anything, and nothing
/// here remembers which intervals are open, only how many.
fn peakOverlap(events: []const Event) struct { rooms: i32, at: i32 } {
    var live: i32 = 0;
    var best: i32 = 0;
    var best_at: i32 = 0;
    for (events) |e| {
        live += e.delta;
        if (live > best) {
            best = live;
            best_at = e.at;
        }
    }
    return .{ .rooms = best, .at = best_at };
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>2}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the tables readable.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// One interval in a fixed eight columns, so a table lines up.
fn writeInterval(out: *std.Io.Writer, iv: Interval) !void {
    try out.writeByte('[');
    try writeCell(out, iv.start, 2);
    try out.writeAll(", ");
    try writeCell(out, iv.end, 2);
    try out.writeByte(']');
}

/// Two lists of intervals hold the same intervals in the same order.
///
/// `std.mem.eql` wants a type it can compare with `!=`, which a struct is not.
fn sameRuns(a: []const Interval, b: []const Interval) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end) return false;
    }
    return true;
}

/// A row of intervals on one line, unpadded.
fn writeList(out: *std.Io.Writer, list: []const Interval) !void {
    for (list) |iv| try out.print(" [{d}, {d}]", .{ iv.start, iv.end });
    try out.writeByte('\n');
}

/// The start row and the end row of a table of intervals.
fn writeRows(out: *std.Io.Writer, list: []const Interval) !void {
    try out.writeAll("  start");
    for (list) |iv| try writeCell(out, iv.start, 5);
    try out.writeAll("\n  end  ");
    for (list) |iv| try writeCell(out, iv.end, 5);
    try out.writeAll("\n");
}

/// The merge pass again, printing what each interval did to the open run.
///
/// Kept separate so `merge` stays the shape you would paste into a solution.
/// The run below checks that the two agree rather than trusting that they do.
fn traceMerge(
    out: *std.Io.Writer,
    sorted: []const Interval,
    take_max: bool,
    scratch: []Interval,
) ![]Interval {
    try out.writeAll("  interval  test      action    run so far\n");
    var count: usize = 0;
    for (sorted) |iv| {
        try out.writeAll("  ");
        try writeInterval(out, iv);
        try out.writeAll("  ");
        if (count == 0) {
            try out.writeAll("first   ");
        } else {
            const open_end = scratch[count - 1].end;
            try writeCell(out, iv.start, 2);
            try out.writeAll(if (iv.start <= open_end) " <= " else " >  ");
            try writeCell(out, open_end, 2);
        }
        if (count > 0 and iv.start <= scratch[count - 1].end) {
            const before = scratch[count - 1].end;
            scratch[count - 1].end = if (take_max)
                @max(before, iv.end)
            else
                iv.end;
            const after = scratch[count - 1].end;
            const word = if (after > before)
                "extended"
            else if (after == before)
                "covered "
            else
                "shrunk  ";
            try out.print("  {s}  ", .{word});
        } else {
            scratch[count] = iv;
            count += 1;
            try out.writeAll("  opened    ");
        }
        try writeInterval(out, scratch[count - 1]);
        try out.writeByte('\n');
    }
    return scratch[0..count];
}

/// The width of the coordinate map, in coordinates.
const map_width = 46;

/// Two ruler lines, tens above units, over the map.
fn writeRuler(out: *std.Io.Writer) !void {
    try out.splatByteAll(' ', 14);
    var tens: [map_width]u8 = undefined;
    @memset(&tens, ' ');
    var mark: usize = 0;
    while (mark < map_width) : (mark += 10) tens[mark] = '0' + @as(u8, @intCast(mark / 10));
    try out.writeAll(std.mem.trimEnd(u8, &tens, " "));
    try out.writeByte('\n');
    try out.splatByteAll(' ', 14);
    for (0..map_width) |c| try out.writeByte('0' + @as(u8, @intCast(c % 10)));
    try out.writeByte('\n');
}

/// One labelled row of the coordinate map.
fn writeMap(out: *std.Io.Writer, label: []const u8, marks: []const u8) !void {
    try out.print("  {s}", .{label});
    try out.splatByteAll(' ', 12 - label.len);
    try out.writeAll(marks);
    try out.writeByte('\n');
}

/// Mark every coordinate any of `list` covers.
///
/// The check shares no line of reasoning with the pass above. It does not
/// sort, it does not know what a run is, and it would give the same answer if
/// the input arrived backwards.
fn paint(list: []const Interval, marks: []u8) void {
    @memset(marks, '.');
    for (list) |iv| {
        var c = iv.start;
        while (c <= iv.end) : (c += 1) marks[@intCast(c)] = '#';
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var storage: [32]Interval = undefined;
    const intervals = try readIntervals(&reader, &storage);

    try out.print("{d} intervals, in the order they arrived\n", .{intervals.len});
    try writeRows(out, intervals);

    std.mem.sort(Interval, intervals, {}, byStart);
    try out.writeAll("\nsorted by start, the only preparation the pass needs\n");
    try writeRows(out, intervals);

    // The traced pass, and the plain one it has to agree with.
    var traced_storage: [32]Interval = undefined;
    var merged_storage: [32]Interval = undefined;
    try out.writeAll("\none pass, each interval against the run being built\n");
    const traced = try traceMerge(out, intervals, true, &traced_storage);
    const merged = merge(intervals, &merged_storage);
    try out.print("  {d} runs:", .{merged.len});
    try writeList(out, merged);
    try out.print(
        "  traced and plain agree -> {}\n",
        .{sameRuns(traced, merged)},
    );

    // The same pass with the end taken from the interval instead of from the
    // larger of the two.
    var wrong_storage: [32]Interval = undefined;
    var wrong_trace: [32]Interval = undefined;
    try out.writeAll("\nthe same pass with end = next end, in place of the larger end\n");
    _ = try traceMerge(out, intervals, false, &wrong_trace);
    const wrong = mergeTakingLast(intervals, &wrong_storage);
    try out.print("  {d} runs:", .{wrong.len});
    try writeList(out, wrong);

    // A coordinate map, painted from the input and from each answer.
    var from_input: [map_width]u8 = undefined;
    var from_merged: [map_width]u8 = undefined;
    var from_wrong: [map_width]u8 = undefined;
    paint(intervals, &from_input);
    paint(merged, &from_merged);
    paint(wrong, &from_wrong);

    try out.writeAll("\nevery coordinate the input covers, against both answers\n");
    try writeRuler(out);
    try writeMap(out, "input", &from_input);
    try writeMap(out, "merged", &from_merged);
    try writeMap(out, "end = next", &from_wrong);
    try out.print(
        "  merged matches the input -> {}\n",
        .{std.mem.eql(u8, &from_input, &from_merged)},
    );
    try out.writeAll("  end = next drops:");
    for (from_input, from_wrong, 0..) |a, b, c| {
        if (a != b) try out.print(" {d}", .{c});
    }
    try out.writeByte('\n');

    // Merging cannot answer how many are open at once, so build events.
    var event_storage: [64]Event = undefined;
    var event_count: usize = 0;
    for (intervals) |iv| {
        event_storage[event_count] = .{ .at = iv.start, .delta = 1, .owner = iv };
        event_storage[event_count + 1] = .{ .at = iv.end, .delta = -1, .owner = iv };
        event_count += 2;
    }
    const events = event_storage[0..event_count];
    std.mem.sort(Event, events, {}, startsFirst);

    const peak = peakOverlap(events);
    try out.writeAll("\nthe same intervals as events, sorted by coordinate\n");
    try out.writeAll("  at  interval  event   rooms\n");
    var live: i32 = 0;
    var marked = false;
    for (events) |e| {
        live += e.delta;
        try out.writeAll("  ");
        try writeCell(out, e.at, 2);
        try out.writeAll("  ");
        try writeInterval(out, e.owner);
        try out.print("  {s}  ", .{if (e.delta > 0) "starts" else "ends  "});
        try writeCell(out, live, 2);
        if (!marked and live == peak.rooms) {
            marked = true;
            try out.writeAll("  <- peak");
        }
        try out.writeByte('\n');
    }
    try out.print(
        "  {d} rooms at their busiest, first at coordinate {d}\n",
        .{ peak.rooms, peak.at },
    );

    // The same count, taken one coordinate at a time.
    var depth: [map_width]u8 = undefined;
    @memset(&depth, '.');
    var deepest: u8 = 0;
    var deepest_at: usize = 0;
    for (0..map_width) |c| {
        var n: u8 = 0;
        for (intervals) |iv| {
            if (iv.start <= @as(i32, @intCast(c)) and @as(i32, @intCast(c)) <= iv.end) n += 1;
        }
        if (n > 0) depth[c] = '0' + n;
        if (n > deepest) {
            deepest = n;
            deepest_at = c;
        }
    }
    try out.writeAll("\nintervals in use at each coordinate, counted one at a time\n");
    try writeRuler(out);
    try writeMap(out, "in use", &depth);
    try out.print(
        "  deepest {d} at coordinate {d}, sweep said {d} at {d}, agree -> {}\n",
        .{
            deepest,
            deepest_at,
            peak.rooms,
            peak.at,
            deepest == peak.rooms and deepest_at == peak.at,
        },
    );

    // The other convention, on the same data. An interval read as [start, end)
    // releases its coordinate before the next one claims it, and [40, 40)
    // holds nothing at all.
    var half_storage: [64]Event = undefined;
    var half_count: usize = 0;
    for (intervals) |iv| {
        if (iv.start == iv.end) continue;
        half_storage[half_count] = .{ .at = iv.start, .delta = 1, .owner = iv };
        half_storage[half_count + 1] = .{ .at = iv.end, .delta = -1, .owner = iv };
        half_count += 2;
    }
    const half = half_storage[0..half_count];
    std.mem.sort(Event, half, {}, endsFirst);
    const half_peak = peakOverlap(half);

    var half_merged: [32]Interval = undefined;
    const half_runs = merge(intervals, &half_merged);
    try out.print(
        "\nthe same {d} intervals read as half-open, [start, end)\n",
        .{intervals.len},
    );
    try out.print(
        "  {d} rooms at their busiest, first at coordinate {d}\n",
        .{ half_peak.rooms, half_peak.at },
    );
    try out.print("  {d} runs, unchanged:", .{half_runs.len});
    try writeList(out, half_runs);
    try out.print(
        "  [40, 40) holds nothing, so {d} intervals became events, not {d}\n",
        .{ half.len / 2, events.len / 2 },
    );

    try out.flush();
}
