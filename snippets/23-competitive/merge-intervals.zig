//! title: Merge Intervals
//! A sort by start, then one pass that compares an interval only with the
//! current run. The program prints the list before and after the sort, and a
//! row for each merge step. It also prints the same pass with the end from the
//! wrong place, and a sweep that counts the intervals that overlap at one time.
//! An independent map of the coordinates checks the two answers.

const std = @import("std");

/// The intervals, as text, one per line: start then end.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The intervals are in the order that they arrived, and that order has
/// no pattern. The parser below reads the text in the same way that it reads a
/// real file.
///
/// `1 20` with `3 5` inside it is the case that finds a merge without `@max`.
/// `3 5` next to `5 8`, and `24 26` next to `26 29`, are the pairs that touch
/// at one coordinate.
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

/// A closed interval: `start` and `end` are both inside the interval.
///
/// Thus `[3, 5]` and `[5, 8]` share the coordinate 5, and they overlap. The
/// other convention, half-open, writes them as `[3, 5)` and `[5, 8)`. Then the
/// two intervals do not overlap.
const Interval = struct {
    start: i32,
    end: i32,
};

/// The comparator that `std.mem.sort` needs: true when `a` goes before `b`.
///
/// Only the start decides which interval the pass gets first. For equal
/// starts, the comparator also uses the end. This costs nothing, and the
/// printed table is always the same.
/// [Sorting](/learn/standard-library/sorting/) has the rest of `std.mem.sort`.
fn byStart(_: void, a: Interval, b: Interval) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

/// Read one interval per line into `out`.
///
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. The function changes
/// bytes into values. Thus the same code works with a file, a socket, or a
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

/// Merge the intervals that overlap. `sorted` must already be in order of start.
///
/// In sorted input, an interval can only overlap the run that is open now.
/// Each earlier run ended before this run started. Each later interval starts
/// at the same point as this interval or after it. Thus there is nothing else
/// to compare with.
///
/// Use `<=`, not `<`, because these intervals are closed, and `[3, 5]` meets
/// `[5, 8]` at the coordinate 5.
///
/// Use `@max`, not `iv.end`. A nested interval such as `[3, 5]` inside
/// `[1, 20]` has a smaller end. If the run takes that end, the run becomes
/// shorter and ends at five.
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

/// The same pass without `@max`. This is a common first attempt.
///
/// The change looks safe: the intervals are sorted, thus the next end must be
/// the larger end. This is true for each interval, except for the intervals
/// that are already inside the run.
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
/// there only to let the trace show the interval.
const Event = struct {
    at: i32,
    delta: i32,
    owner: Interval,
};

/// Sort the events by coordinate. At the same coordinate, put a start before
/// an end.
///
/// The rule for equal coordinates comes from the closed convention again.
/// `[24, 26]` and `[26, 29]` both hold the coordinate 26. Thus the two
/// intervals are both in use there, and the count must increase before it
/// decreases.
fn startsFirst(_: void, a: Event, b: Event) bool {
    if (a.at != b.at) return a.at < b.at;
    return a.delta > b.delta;
}

/// The half-open convention: at the same coordinate, an end goes first.
fn endsFirst(_: void, a: Event, b: Event) bool {
    if (a.at != b.at) return a.at < b.at;
    return a.delta < b.delta;
}

/// The largest number of intervals in use at one coordinate, and the first
/// coordinate where this occurs.
///
/// The count that changes at each event is the answer. This function does not
/// merge intervals. It does not record which intervals are open, only how
/// many intervals are open.
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
/// `{d:>2}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the tables are easy to read.
fn writeCell(out: *std.Io.Writer, value: i32, width: usize) !void {
    var digits: [12]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// One interval in eight columns. Thus the columns of a table align.
fn writeInterval(out: *std.Io.Writer, iv: Interval) !void {
    try out.writeByte('[');
    try writeCell(out, iv.start, 2);
    try out.writeAll(", ");
    try writeCell(out, iv.end, 2);
    try out.writeByte(']');
}

/// True if two lists hold the same intervals in the same order.
///
/// `std.mem.eql` needs a type that it can compare with `!=`. A struct is not
/// such a type.
fn sameRuns(a: []const Interval, b: []const Interval) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end) return false;
    }
    return true;
}

/// A row of intervals on one line, without padding.
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

/// The merge pass again. It prints the change that each interval made to the
/// open run.
///
/// This function is separate, thus `merge` keeps the shape that you can copy
/// into a solution. The run below checks that the two functions agree. It
/// does not assume that they do.
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

/// Mark each coordinate that an interval in `list` covers.
///
/// The check does not use the logic of the pass above. It does not sort, and
/// it does not know what a run is. If the input arrived in reverse order, the
/// answer is the same.
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

    // The pass with a trace, and the plain pass. The two must agree.
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

    // The same pass, with the end from the interval instead of the larger of
    // the two ends.
    var wrong_storage: [32]Interval = undefined;
    var wrong_trace: [32]Interval = undefined;
    try out.writeAll("\nthe same pass with end = next end, in place of the larger end\n");
    _ = try traceMerge(out, intervals, false, &wrong_trace);
    const wrong = mergeTakingLast(intervals, &wrong_storage);
    try out.print("  {d} runs:", .{wrong.len});
    try writeList(out, wrong);

    // A map of the coordinates, from the input and from each answer.
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

    // A merge cannot tell how many intervals are open at one time. Thus make
    // events.
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

    // The same count, one coordinate at a time.
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

    // The other convention, on the same data. With [start, end), an interval
    // releases its end coordinate before the next interval takes it. [40, 40)
    // holds no coordinates.
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
