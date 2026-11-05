# Merge Intervals

> A sort by start for one pass, the nested interval that shortens a run without @max, and a sweep that counts open intervals.

The example below has eleven intervals. The problem is to combine the intervals that overlap. The input has three special cases:

- Some intervals are fully inside `[1, 20]`.
- `[3, 5]` ends where `[5, 8]` starts.
- `[40, 40]` holds only one coordinate.

If the intervals are in random order, it is difficult to know which intervals can overlap. A sort by start position makes the problem much simpler.

After the sort, the pass reads the intervals from left to right and keeps one merged interval open at a time. For each new interval, the pass only has to check if the interval overlaps the current merged interval.

The program sorts the intervals and shows each step of the merge. It also marks each coordinate that the intervals cover, and it uses these marks to check the result.

```zig
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
/// [Sorting](https://www.ziglang.in/learn/standard-library/sorting/) has the rest of `std.mem.sort`.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.merge-intervals`)*

## Sort by start, then make one pass

```zig
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
```

*Quoted from the source: `merge` from `snippets/23-competitive/merge-intervals.zig`.*

For each new interval, there are two cases:

- If the new interval starts before or at the end of the current merged interval, the two intervals overlap. The pass extends the current merged interval if necessary.
- If the new interval starts after the end of the current merged interval, there is a gap. The current merged interval is complete, and the pass starts a new merged interval.

The program sorts the intervals by start position. Thus the pass never has to check an older merged interval again, because the starts only move forward.

The sorted input is:

```
sorted by start, the only preparation the pass needs
  start    1    3    4    5   12   13   18   24   26   33   40
  end     20    5    7    8   15   17   21   26   29   36   40
```

The pass needs sorted starts only. The end values can be in any order. For example, `[1, 20]` is first, but its end value is larger than the end values of some intervals after it.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) explains `std.mem.sort` and the rules for a comparator.

The steps of the merge are:

```
  interval  test      action    run so far
  [ 1, 20]  first     opened    [ 1, 20]
  [ 3,  5]   3 <= 20  covered   [ 1, 20]
  [ 4,  7]   4 <= 20  covered   [ 1, 20]
  [ 5,  8]   5 <= 20  covered   [ 1, 20]
  [12, 15]  12 <= 20  covered   [ 1, 20]
  [13, 17]  13 <= 20  covered   [ 1, 20]
  [18, 21]  18 <= 20  extended  [ 1, 21]
  [24, 26]  24 >  21  opened    [24, 26]
  [26, 29]  26 <= 26  extended  [24, 29]
  [33, 36]  33 >  29  opened    [33, 36]
  [40, 40]  40 >  36  opened    [40, 40]
  4 runs: [1, 21] [24, 29] [33, 36] [40, 40]
```

Some intervals are fully inside `[1, 20]`. Thus they do not change the current merged interval. `[18, 21]` overlaps `[1, 20]` and extends the end from 20 to 21. `[24, 26]` starts after 21, thus a new merged interval starts.

The sort takes O(n log n), and the merge takes O(n). Thus the full algorithm takes O(n log n).

## Use @max for the merged end

```zig
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
```

*Quoted from the source: `mergeTakingLast` from `snippets/23-competitive/merge-intervals.zig`.*

When two intervals overlap, a simple method is to replace the current end with the end of the new interval. This method is wrong when one interval is fully inside a different interval.

For example, start with `[1, 20]` and then add `[3, 5]`. If you only assign the new end, the merged interval becomes `[1, 5]`. But the first interval already covered all of the coordinates up to 20. Thus the merge shortened the interval incorrectly.

The incorrect version gives these steps:

```
  [ 1, 20]  first     opened    [ 1, 20]
  [ 3,  5]   3 <= 20  shrunk    [ 1,  5]
  [ 4,  7]   4 <=  5  extended  [ 1,  7]
  [ 5,  8]   5 <=  7  extended  [ 1,  8]
  [12, 15]  12 >   8  opened    [12, 15]
```

After `[3, 5]`, the end decreases from 20 to 5. The next intervals slowly increase the end again. But now `[12, 15]` seems to start after the current end. Thus the merge starts a new merged interval that must not exist.

The last result is:

```
  6 runs: [1, 8] [12, 17] [18, 21] [24, 29] [33, 36] [40, 40]
```

The correct result has four merged intervals.

The correct update is `end = @max(end, iv.end)`. When intervals overlap, the merged interval must keep the end that goes further.

The figure runs both passes on the sorted intervals. Select a rule, and step through the intervals. At the second interval, `[3, 5]`, the two rules separate.

*Figure: 11 sorted intervals on a number line, merged into runs. With the larger end there are 4 runs; with the next end there are 6. The two passes from the program above. Select a rule and step through the intervals. The steps have the same names, thus you can switch at any step.*

## Check the merged result

The number of merged intervals is not sufficient to verify the algorithm. An incorrect result can have the correct number of intervals and still have wrong boundaries. Thus the example checks the coverage directly.

```zig
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
```

*Quoted from the source: `paint` from `snippets/23-competitive/merge-intervals.zig`.*

These coordinates are small. Thus the program marks each coordinate that the original intervals cover, and compares the marks with the merged result.

```
every coordinate the input covers, against both answers
              0         1         2         3         4
              0123456789012345678901234567890123456789012345
  input       .#####################..######...####...#.....
  merged      .#####################..######...####...#.....
  end = next  .########...##########..######...####...#.....
  merged matches the input -> true
  end = next drops: 9 10 11
```

The correct merged result covers exactly the same coordinates as the input. The incorrect version loses the coordinates 9, 10 and 11.

Those coordinates are part of `[1, 20]`. The incorrect result does not cover them, because the incorrect merge shortened the first run to `[1, 8]`, and the next run starts at 12.

A check of each coordinate is useful for small test cases. It is not suitable for very large coordinates, for example timestamps or values in the millions or billions.

## Closed intervals that touch

This example uses closed intervals. The closed interval `[3, 5]` holds 3, 4 and 5. The interval `[5, 8]` also holds 5. Thus the two intervals overlap at the coordinate 5.

For this reason, the merge condition uses `<=`: `iv.start <= current.end`.

The same condition occurs here:

```
  [24, 26]  24 >  21  opened    [24, 26]
  [26, 29]  26 <= 26  extended  [24, 29]
```

The two intervals both include 26. Thus they overlap, and the pass merges them.

If the test uses `<` instead of `<=`, the two intervals stay separate. They still cover the same coordinates, but the result has more intervals than necessary.

## Half-open intervals

A half-open interval has the form `[start, end)`. The interval includes the start, but it does not include the end.

For example, `[3, 5)` holds 3 and 4, and `[5, 8)` holds 5, 6 and 7. These two intervals do not overlap. But they touch, and there is no gap between them.

If the goal is to show their union with as few intervals as possible, you can still combine them into `[3, 8)`. Thus the same `<=` test can still be useful when the merge must combine half-open intervals that touch.

Choose one interval convention, and use it in all parts of the solution.

## Intervals over whole-number positions

Some problems use intervals for discrete values, for example days, seats or integer coordinates. In such a problem, `[1, 3]` holds 1, 2 and 3, and `[4, 6]` holds 4, 5 and 6. There is no unused integer between 3 and 4.

If the problem wants the merge to combine adjacent integer ranges, these two intervals can become `[1, 6]`. Then the condition is `iv.start <= out[count - 1].end + 1`.

Ordinary continuous closed intervals do not use the `+ 1`. Thus, before you write the merge condition, decide what the interval boundaries mean in the problem.

## A merge cannot count overlaps

Merged intervals tell you which coordinates the intervals cover. They do not tell you how many original intervals overlap at the same point.

For example, the merged interval `[1, 21]` is only one interval in the output. But at the coordinate 5, four original intervals are active at the same time. If these intervals are meetings, four rooms are necessary. If they are jobs, four machines can be necessary.

The merge does not keep this information. To count intervals that are active at the same time, you need a sweep-line algorithm.

```zig
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
```

*Quoted from the source: `peakOverlap` from `snippets/23-competitive/merge-intervals.zig`.*

The sweep has these steps:

1. Change each interval into two events. A start event adds 1, and an end event subtracts 1.
2. Sort all of the events by coordinate.
3. Read the events from left to right, and keep a total.

The total tells you how many intervals are active.

The first seven events are:

```
  at  interval  event   rooms
   1  [ 1, 20]  starts   1
   3  [ 3,  5]  starts   2
   4  [ 4,  7]  starts   3
   5  [ 5,  8]  starts   4  <- peak
   5  [ 3,  5]  ends     3
   7  [ 4,  7]  ends     2
   8  [ 5,  8]  ends     1
```

The maximum number of active intervals is four.

## Put the events in the correct order

Two events occur at the coordinate 5. `[5, 8]` starts there, and `[3, 5]` ends there.

This sweep uses closed intervals. Thus the two intervals both hold the coordinate 5, and the sweep must use the start event before the end event. Then the two intervals both count as active at the same coordinate.

```zig
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
```

*Quoted from the source: `startsFirst` from `snippets/23-competitive/merge-intervals.zig`.*

The order of the events must agree with the interval convention of the merge. For closed intervals, the sweep uses starts at the same coordinate before ends.

The program verifies the sweep. It counts the active intervals at each coordinate, one coordinate at a time:

```
intervals in use at each coordinate, counted one at a time
              0         1         2         3         4
              0123456789012345678901234567890123456789012345
  in use      .112343321112333222221..112111...1111...1.....
  deepest 4 at coordinate 5, sweep said 4 at 5, agree -> true
```

The digit at each position shows how many intervals cover that coordinate. The maximum is 4 at the coordinate 5. The dots at the coordinates 22 and 23 show the gap between the first and the second merged interval.

## Half-open intervals change the overlap count

Now read the same intervals as half-open, `[start, end)`. Then `[3, 5)` is not active at the coordinate 5. `[5, 8)` starts exactly where `[3, 5)` ends. Thus the two intervals are not active at the same time.

The program shows:

```
the same 11 intervals read as half-open, [start, end)
  3 rooms at their busiest, first at coordinate 4
  4 runs, unchanged: [1, 21] [24, 29] [33, 36] [40, 40]
  [40, 40) holds nothing, so 10 intervals became events, not 11
```

The peak overlap decreases from four to three.

Also, `[40, 40)` is empty. It holds no coordinates, thus it does not need start and end events.

The merged runs did not change, but the overlap count changed.

## Merge and sweep answer different questions

The merge keeps the start and the end of the current combined interval. Thus the merge tells you which regions the intervals cover.

The sweep keeps a count. Thus the sweep tells you how many intervals are active at the same time.

If a problem asks for the merged ranges and also the maximum overlap, use two separate passes over the sorted data.
