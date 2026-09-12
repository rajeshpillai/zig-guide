# Merge Intervals

> Sorting by start so a single pass is enough, the nested interval that shortens a run when @max is missing, and the sweep that counts how many intervals are open at once.

Suppose we have several intervals and want to combine all overlapping ones.

If the intervals are in random order, it is difficult to know which intervals may overlap.

Sorting them by start position makes the problem much simpler.

After sorting, we can process the intervals from left to right and keep one merged interval open at a time.

For each new interval, we only need to check whether it overlaps the current merged interval.

The example below contains eleven intervals.

Some are completely inside `[1, 20]`.

`[3, 5]` ends where `[5, 8]` begins.

`[40, 40]` contains a single coordinate.

The program sorts the intervals, shows what happens at each step, and also checks the final result by marking every covered coordinate.

```zig
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
/// [Sorting](https://www.ziglang.in/learn/standard-library/sorting/) has the rest of `std.mem.sort`.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.merge-intervals`)*

## Sort by start, then make one pass

<SnippetSource name="23-competitive.merge-intervals" decl="merge" />

After sorting, we keep one merged interval open.

For each new interval, there are two cases.

If the new interval starts before or at the end of the current merged interval, the two intervals overlap.

We extend the current merged interval if needed.

If the new interval starts after the current merged interval ends, there is a gap.

The current merged interval is complete, and we start a new one.

Because the intervals are sorted by start position, an older merged interval never needs to be checked again.

The starts only move forward.

The sorted input is:

```
sorted by start, the only preparation the pass needs
  start    1    3    4    5   12   13   18   24   26   33   40
  end     20    5    7    8   15   17   21   26   29   36   40
```

Only the starts need to be sorted.

The end values do not need to be sorted.

For example, `[1, 20]` appears first even though its end value is larger than several intervals that follow it.

[Sorting](https://www.ziglang.in/learn/standard-library/sorting/) covers `std.mem.sort` and the rules a comparator has to follow.

The merge proceeds like this:

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

Several intervals are completely contained inside `[1, 20]`, so they do not change the current merged interval.

`[18, 21]` overlaps it and extends the end from 20 to 21.

`[24, 26]` starts after 21, so a new merged interval begins.

Sorting takes O(n log n).

The merge itself takes O(n).

So the total time complexity is:

`O(n log n)`

## The merged end must use @max

<SnippetSource name="23-competitive.merge-intervals" decl="mergeTakingLast" />

When two intervals overlap, it is tempting to replace the current end with the end of the new interval.

That is wrong when one interval is completely inside another.

For example, start with:

`[1, 20]`

Then process:

`[3, 5]`

If we simply assign the new end, the merged interval becomes:

`[1, 5]`

But the original interval already covered everything up to 20.

We have incorrectly shortened it.

The broken version behaves like this:

```
  [ 1, 20]  first     opened    [ 1, 20]
  [ 3,  5]   3 <= 20  shrunk    [ 1,  5]
  [ 4,  7]   4 <=  5  extended  [ 1,  7]
  [ 5,  8]   5 <=  7  extended  [ 1,  8]
  [12, 15]  12 >   8  opened    [12, 15]
```

After processing `[3, 5]`, the end falls from 20 to 5.

The following intervals slowly increase it again, but `[12, 15]` now appears to start after the current end.

That creates a new merged interval that should not exist.

The final result becomes:

```
  6 runs: [1, 8] [12, 17] [18, 21] [24, 29] [33, 36] [40, 40]
```

The correct result has four merged intervals.

The correct update is:

`end = @max(end, iv.end)`

When intervals overlap, the merged interval must keep whichever end reaches further.

## Checking the merged result

Counting the number of merged intervals is not enough to verify the algorithm.

A broken result may have the correct number of intervals but still contain wrong boundaries.

The example therefore checks coverage directly.

<SnippetSource name="23-competitive.merge-intervals" decl="paint" />

For these small coordinates, the program marks every coordinate covered by the original intervals and compares that with the merged result.

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

The correct merged result covers exactly the same coordinates as the input.

The broken version loses coordinates 9, 10 and 11.

Those coordinates belong to `[1, 20]`.

They disappear because the broken merge shortened the first run to `[1, 8]`, while the next run starts at 12.

This kind of coordinate-by-coordinate check is useful for small test cases.

It is not suitable for very large coordinates such as timestamps or values in the millions or billions.

## Closed intervals and touching intervals

The intervals in this example are closed.

A closed interval:

`[3, 5]`

contains 3, 4 and 5.

Another interval:

`[5, 8]`

also contains 5.

So the intervals overlap at coordinate 5.

That is why the merge condition is:

`iv.start <= current.end`

The same situation appears here:

```
  [24, 26]  24 >  21  opened    [24, 26]
  [26, 29]  26 <= 26  extended  [24, 29]
```

Because both intervals include 26, they overlap and are merged.

If the test used `<` instead of `<=`, the two intervals would remain separate.

They would still cover the same coordinates, but the result would contain more intervals than necessary.

## Half-open intervals

Half-open intervals use the form:

`[start, end)`

The start is included.

The end is excluded.

For example:

`[3, 5)`

contains 3 and 4.

`[5, 8)`

contains 5, 6 and 7.

These two intervals do not overlap.

However, they touch without leaving a gap.

If the goal is to represent their union using as few intervals as possible, they can still be combined into:

`[3, 8)`

So the same `<=` test can still be useful when touching half-open intervals should be merged.

The important part is to choose one interval convention and use it consistently.

## Intervals over whole-number positions

Some problems use intervals to represent discrete values such as days, seats or integer coordinates.

In that case:

`[1, 3]`

contains 1, 2 and 3.

And:

`[4, 6]`

contains 4, 5 and 6.

There is no unused integer between 3 and 4.

If the problem wants adjacent integer ranges merged, these can become:

`[1, 6]`

The condition then becomes:

`iv.start <= out[count - 1].end + 1`

This is different from ordinary continuous closed intervals.

So before writing the merge condition, decide what the interval boundaries mean in the problem.

## Merging cannot count overlaps

Merged intervals tell us which coordinates are covered.

They do not tell us how many original intervals overlap at the same point.

For example, the merged interval:

`[1, 21]`

is only one interval in the output.

But at coordinate 5, four original intervals are active at the same time.

If these intervals represent meetings, that means four rooms are required.

If they represent jobs, four machines may be required.

The merge operation loses this information.

To count simultaneous intervals, we need a sweep-line algorithm.

<SnippetSource name="23-competitive.merge-intervals" decl="peakOverlap" />

Each interval becomes two events.

A start event adds 1.

An end event subtracts 1.

Sort all events by coordinate and process them from left to right.

The running total tells us how many intervals are active.

For example:

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

## Event order matters

Two events occur at coordinate 5.

`[5, 8]` starts there.

`[3, 5]` ends there.

Because these are closed intervals, both intervals contain coordinate 5.

So the start event must be processed before the end event.

That allows both intervals to count as active at the same coordinate.

<SnippetSource name="23-competitive.merge-intervals" decl="startsFirst" />

The event ordering must match the same interval convention used by the merge.

For closed intervals:

starts at the same coordinate are processed before ends.

The program verifies the sweep by counting active intervals coordinate by coordinate:

```
intervals in use at each coordinate, counted one at a time
              0         1         2         3         4
              0123456789012345678901234567890123456789012345
  in use      .112343321112333222221..112111...1111...1.....
  deepest 4 at coordinate 5, sweep said 4 at 5, agree -> true
```

The digit at each position shows how many intervals cover that coordinate.

The maximum is 4 at coordinate 5.

The dots at coordinates 22 and 23 show the gap between the first and second merged intervals.

## Half-open intervals change the overlap count

Now interpret the same intervals as half-open:

`[start, end)`

Then `[3, 5)` is no longer active at coordinate 5.

`[5, 8)` starts exactly where it ends.

So they are not active at the same time.

The program shows:

```
the same 11 intervals read as half-open, [start, end)
  3 rooms at their busiest, first at coordinate 4
  4 runs, unchanged: [1, 21] [24, 29] [33, 36] [40, 40]
  [40, 40) holds nothing, so 10 intervals became events, not 11
```

The peak overlap falls from four to three.

Also:

`[40, 40)`

is empty.

It contains no coordinates, so it does not need start and end events.

This shows why interval conventions matter.

The merged output may look the same while other answers, such as overlap counts, change.

## Merge and sweep solve different questions

Both algorithms start by sorting and then make one pass.

Merging answers:

Which regions are covered?

A sweep answers:

How many intervals are active at the same time?

The merge keeps the start and end of the current combined interval.

The sweep keeps a running count.

Neither one automatically gives the information stored by the other.

If a problem asks for both the merged ranges and the maximum overlap, handle them as two separate operations over the sorted data.
