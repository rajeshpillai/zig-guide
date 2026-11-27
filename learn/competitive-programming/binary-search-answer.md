# Binary Search on the Answer

> Search a range of possible answers instead of an array, with a greedy pack as the predicate and a full scan to check the boundary.

A company ships packages by boat, and it has a list of packages. The company must load the packages onto a boat in the same order that they arrive. The goal is to ship all of the packages in four days or fewer.

The task is to find the minimum capacity of the boat. The input does not contain this value directly. Thus there is no sorted array to search.

But for each capacity, you can ask a simple question:

Can a boat with this capacity ship all of the packages in four days or fewer?

For example, a capacity of 9 tonnes is not sufficient. A capacity of 61 tonnes is sufficient. Also, if a capacity works, each larger capacity also works.

Thus the results have this shape:

```
no no no no ... yes yes yes yes ...
```

The answer changes from `no` to `yes` at one point. Binary search can find that point.

```zig
const std = @import("std");

/// The problem: package weights in the order of arrival, then the number of days.
const input =
    \\5 3 8 2 9 4 7 6 1 8 3 5
    \\4
;

/// Read one line of whitespace-separated values into `out`.
fn readRow(reader: *std.Io.Reader, out: []u32) ![]u32 {
    const line = (try reader.takeDelimiter('\n')) orelse return error.MissingRow;
    var count: usize = 0;
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        if (count == out.len) return error.RowTooLong;
        out[count] = try std.fmt.parseInt(u32, field, 10);
        count += 1;
    }
    return out[0..count];
}

/// The ship, the deadline, and a count of the calls to the predicate.
///
/// The ship loads the packages in the order of arrival. Thus a capacity sets
/// the full plan. Fill the current day until the next package does not fit,
/// then start the next day. `calls` counts each call to the predicate. Thus
/// you can compare the cost of the two searches below.
const Ship = struct {
    weights: []const u32,
    limit: u32,
    calls: usize = 0,

    /// The days necessary at this capacity, or null when a package does not fit.
    fn daysNeeded(self: *Ship, cap: u32) ?u32 {
        self.calls += 1;
        var days: u32 = 1;
        var load: u32 = 0;
        for (self.weights) |w| {
            if (w > cap) return null;
            if (load + w > cap) {
                days += 1;
                load = 0;
            }
            load += w;
        }
        return days;
    }

    /// True when this capacity completes the work in the time limit.
    ///
    /// The result is false below the boundary and true at or above it. It
    /// changes one time. No other code in this file can assume this property.
    /// The run below checks it.
    fn feasible(self: *Ship, cap: u32) bool {
        const days = self.daysNeeded(cap) orelse return false;
        return days <= self.limit;
    }

    /// The same question with a second condition: on each day, half of the
    /// hold or more must be full.
    ///
    /// This plan looks better, but the predicate is not monotonic. A big ship
    /// completes the work early and is half empty on the last day. Thus a
    /// capacity that works can fail when you add one tonne to it.
    fn feasibleAndFull(self: *Ship, cap: u32) bool {
        const days = self.daysNeeded(cap) orelse return false;
        if (days > self.limit) return false;
        var lightest: u32 = std.math.maxInt(u32);
        var load: u32 = 0;
        for (self.weights) |w| {
            if (load + w > cap) {
                lightest = @min(lightest, load);
                load = 0;
            }
            load += w;
        }
        lightest = @min(lightest, load);
        return lightest * 2 >= cap;
    }
};

const Predicate = *const fn (*Ship, u32) bool;

/// The first capacity in `[low, high]` that the predicate accepts.
///
/// The loop is the loop from the binary search chapter, without the array.
/// `items[mid] < key` becomes `!pred(mid)`: mid is too small to be the answer.
/// Thus `lo = mid + 1` removes mid. In the other branch, mid can be the
/// answer, and the loop keeps it. When the window is empty, `lo` is the
/// boundary.
fn firstFeasible(ship: *Ship, low: u32, high: u32, pred: Predicate) u32 {
    var lo = low;
    var hi = high;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pred(ship, mid)) hi = mid else lo = mid + 1;
    }
    return lo;
}

/// The same search, but it prints one row for each step.
///
/// This function is separate. Thus the function above keeps the shape that you
/// can copy into a solution. The run checks that the two functions return the
/// same capacity.
fn traceFirstFeasible(out: *std.Io.Writer, ship: *Ship, low: u32, high: u32) !u32 {
    var lo = low;
    var hi = high;
    var step: u32 = 0;
    try out.writeAll("  step   lo   hi  mid  days  ok   window after\n");
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        step += 1;
        const days = ship.daysNeeded(mid);
        const ok = days != null and days.? <= ship.limit;
        try out.print("  {d:>4} {d:>4} {d:>4} {d:>4}  {d:>4}  {s:<4} ", .{ step, lo, hi, mid, days orelse 0, if (ok) "yes" else "no" });
        if (ok) hi = mid else lo = mid + 1;
        try out.print("[{d:>3},{d:>3}]  {d} left\n", .{ lo, hi, hi - lo + 1 });
    }
    try out.print("  window closed after {d} steps on capacity {d}\n", .{ step, lo });
    return lo;
}

/// One day of the plan: the packages on the boat, then the total weight.
fn writeDay(out: *std.Io.Writer, day: u32, items: []const u32, load: u32) !void {
    try out.print("  day {d}:", .{day});
    var used: usize = 0;
    for (items) |w| {
        try out.print(" {d:>2}", .{w});
        used += 3;
    }
    if (used < 38) try out.splatByteAll(' ', 38 - used);
    try out.print("load {d:>2}\n", .{load});
}

/// Run the greedy pack at one capacity and print the plan that it makes.
fn writePacking(out: *std.Io.Writer, ship: *Ship, cap: u32) !void {
    try out.print("capacity {d}, packed in arrival order\n", .{cap});
    var start: usize = 0;
    var load: u32 = 0;
    var day: u32 = 1;
    for (ship.weights, 0..) |w, i| {
        if (w > cap) {
            try out.print("  package of {d} does not fit at all\n", .{w});
            return;
        }
        if (load + w > cap) {
            try writeDay(out, day, ship.weights[start..i], load);
            day += 1;
            start = i;
            load = 0;
        }
        load += w;
    }
    try writeDay(out, day, ship.weights[start..], load);
    try out.print("  {d} days against a limit of {d} -> {s}\n\n", .{
        day,
        ship.limit,
        if (day <= ship.limit) "feasible" else "too slow",
    });
}

/// The result of a full scan of the range.
const Scan = struct {
    first_true: ?u32,
    flips: usize,
    calls: usize,
};

/// Ask the predicate about each capacity in the range and print the answers.
///
/// The function prints one character for each capacity. Thus you can see the
/// shape of the predicate, and you do not have to assume it. A monotonic
/// predicate changes one time. Binary search cannot answer a different shape.
fn writeScan(out: *std.Io.Writer, ship: *Ship, low: u32, high: u32, pred: Predicate) !Scan {
    const before = ship.calls;
    var first_true: ?u32 = null;
    var flips: usize = 0;
    var previous = false;
    try out.print("  {d:>3} ", .{low});
    var cap = low;
    while (cap <= high) : (cap += 1) {
        const ok = pred(ship, cap);
        try out.writeByte(if (ok) '#' else '.');
        if (ok and first_true == null) first_true = cap;
        if (cap > low and ok != previous) flips += 1;
        previous = ok;
    }
    try out.print(" {d}\n", .{high});
    return .{
        .first_true = first_true,
        .flips = flips,
        .calls = ship.calls - before,
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var weight_storage: [64]u32 = undefined;
    var day_storage: [1]u32 = undefined;
    const weights = try readRow(&reader, &weight_storage);
    const days = try readRow(&reader, &day_storage);

    var heaviest: u32 = 0;
    var total: u32 = 0;
    for (weights) |w| {
        heaviest = @max(heaviest, w);
        total += w;
    }

    var ship: Ship = .{ .weights = weights, .limit = days[0] };
    try out.print("{d} packages, {d} days\n  ", .{ weights.len, ship.limit });
    for (weights) |w| try out.print("{d:>3}", .{w});
    try out.print("\n  heaviest {d}, total {d}\n\n", .{ heaviest, total });

    // The bounds. A capacity below the heaviest package cannot hold that
    // package. One day at the total always works. Thus the boundary is between
    // the two bounds.
    try out.print("search range: [{d}, {d}], {d} candidates\n\n", .{
        heaviest,
        total,
        total - heaviest + 1,
    });

    // The work of one call to the predicate.
    try writePacking(out, &ship, heaviest + (total - heaviest) / 2);

    ship.calls = 0;
    try out.writeAll("binary search over the capacities\n");
    const answer = try traceFirstFeasible(out, &ship, heaviest, total);
    const search_calls = ship.calls;
    try out.print("  plain firstFeasible agrees -> {}\n\n", .{
        answer == firstFeasible(&ship, heaviest, total, Ship.feasible),
    });

    // The two plans on the two sides of the boundary prove the answer.
    try out.writeAll("either side of the boundary\n");
    try writePacking(out, &ship, answer - 1);
    try writePacking(out, &ship, answer);

    ship.calls = 0;
    try out.print("every capacity from {d} to {d}, '#' means feasible\n", .{ heaviest, total });
    const scan = try writeScan(out, &ship, heaviest, total, Ship.feasible);
    try out.print("  first '#' at {?d}, binary search said {d}, agree -> {}\n", .{
        scan.first_true,
        answer,
        scan.first_true == answer,
    });
    try out.print("  the predicate flips {d} time, so it is monotonic\n", .{scan.flips});
    try out.print("  predicate calls: {d} scanning, {d} searching\n\n", .{ scan.calls, search_calls });

    // Move a bound, and the search still returns a number.
    const average = total / ship.limit;
    const bad = firstFeasible(&ship, heaviest, average, Ship.feasible);
    try out.print("with the high bound set to total / days = {d}\n", .{average});
    try out.print("  the search returns {d} and feasible({d}) = {s}\n", .{
        bad,
        bad,
        if (ship.feasible(bad)) "yes" else "no",
    });
    try out.print("  {d} days needed there, limit {d}\n\n", .{ ship.daysNeeded(bad).?, ship.limit });

    // A predicate that changes more than one time. The loop stops and returns
    // a capacity. That capacity is not the smallest one that the predicate
    // accepts.
    ship.calls = 0;
    try out.writeAll("now require every day to fill at least half the hold\n");
    const flicker = try writeScan(out, &ship, heaviest, total, Ship.feasibleAndFull);
    const found = firstFeasible(&ship, heaviest, total, Ship.feasibleAndFull);
    try out.print("  the predicate flips {d} times, so there is no boundary\n", .{flicker.flips});
    try out.print("  binary search returns {d}, first '#' is at {?d}\n", .{ found, flicker.first_true });
    var accepted_below: u32 = 0;
    var cap = heaviest;
    while (cap < found) : (cap += 1) {
        if (ship.feasibleAndFull(cap)) accepted_below += 1;
    }
    try out.print("  feasibleAndFull({d}) = {}, and {d} smaller capacities pass too\n", .{
        found,
        ship.feasibleAndFull(found),
        accepted_below,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.binary-search-answer`)*

## The predicate

```zig
    /// True when this capacity completes the work in the time limit.
    ///
    /// The result is false below the boundary and true at or above it. It
    /// changes one time. No other code in this file can assume this property.
    /// The run below checks it.
    fn feasible(self: *Ship, cap: u32) bool {
        const days = self.daysNeeded(cap) orelse return false;
        return days <= self.limit;
    }
```

*Quoted from the source: `feasible` from `snippets/23-competitive/binary-search-answer.zig`.*

The packages must go onto the boat in the order of arrival. For a given capacity, the function adds packages to the load of the current day. If the next package does not fit, the function starts a new day.

The function has no other choices to make. Thus the same capacity always gives the same number of days for the same list of packages.

`daysNeeded` returns null when one package is heavier than the given capacity. That capacity can never work, because the boat cannot load the package. Thus `feasible` uses `false` for null.

```zig
    /// The days necessary at this capacity, or null when a package does not fit.
    fn daysNeeded(self: *Ship, cap: u32) ?u32 {
        self.calls += 1;
        var days: u32 = 1;
        var load: u32 = 0;
        for (self.weights) |w| {
            if (w > cap) return null;
            if (load + w > cap) {
                days += 1;
                load = 0;
            }
            load += w;
        }
        return days;
    }
```

*Quoted from the source: `daysNeeded` from `snippets/23-competitive/binary-search-answer.zig`.*

For example:

```
capacity 35, packed in arrival order
  day 1:  5  3  8  2  9  4                    load 31
  day 2:  7  6  1  8  3  5                    load 30
  2 days against a limit of 4 -> feasible
```

A capacity of 35 completes the work in two days. Thus the capacity is feasible.

The binary search does not have to know that the work took exactly two days. The binary search needs only the result:

```
true
```

Each call to `feasible` reads the list of packages one time. This is the `n` part of the final time complexity.

## Choose the lower and upper bounds

The lower bound is the weight of the heaviest package. The heaviest package weighs 9 tonnes. Thus the capacity of the boat must be 9 or more. Do not test a value below 9.

The upper bound is the total weight of all of the packages. The total is 61 tonnes. With a capacity of 61, the boat can load all of the packages in one day.

Thus the answer is between 9 and 61. These bounds come directly from the input. Thus they stay correct when the weights of the packages change.

A bound that you guess can make the binary search return the wrong answer. For example, the average load for each day is an incorrect upper bound:

```
with the high bound set to total / days = 15
  the search returns 15 and feasible(15) = no
  6 days needed there, limit 4
```

The binary search returns 15, because 15 is the highest value in the search range. The loop did not make a mistake. The search range was wrong, and the range did not contain a feasible value.

Thus it is useful to check the result after the search:

- The returned answer must be feasible.
- The value immediately below the answer must not be feasible.

## Use a predicate in the binary search

```zig
/// The first capacity in `[low, high]` that the predicate accepts.
///
/// The loop is the loop from the binary search chapter, without the array.
/// `items[mid] < key` becomes `!pred(mid)`: mid is too small to be the answer.
/// Thus `lo = mid + 1` removes mid. In the other branch, mid can be the
/// answer, and the loop keeps it. When the window is empty, `lo` is the
/// boundary.
fn firstFeasible(ship: *Ship, low: u32, high: u32, pred: Predicate) u32 {
    var lo = low;
    var hi = high;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pred(ship, mid)) hi = mid else lo = mid + 1;
    }
    return lo;
}
```

*Quoted from the source: `firstFeasible` from `snippets/23-competitive/binary-search-answer.zig`.*

[Binary Search](https://www.ziglang.in/learn/competitive-programming/binary-search/) explains the half-open search window and the invariant of this loop. The main difference here is the comparison.

A usual lower-bound search can use a comparison such as:

`items[mid] < key`

If the comparison is true, `mid` is too small. Thus the search moves the lower bound to:

`mid + 1`

This search uses:

`!pred(ship, mid)`

If the predicate returns false, that capacity is too small. Thus the search again moves to:

`mid + 1`

If the predicate returns true, `mid` can be the answer. Thus the search keeps `mid` inside the search range.

The structure of the binary search does not change. The search does not read a value from an array. It calls a function that tells if the current value works.

For this example:

```
binary search over the capacities
  step   lo   hi  mid  days  ok   window after
     1    9   61   35     2  yes  [  9, 35]  27 left
     2    9   35   22     4  yes  [  9, 22]  14 left
     3    9   22   15     6  no   [ 16, 22]  7 left
     4   16   22   19     4  yes  [ 16, 19]  4 left
     5   16   19   17     4  yes  [ 16, 17]  2 left
     6   16   17   16     4  yes  [ 16, 16]  1 left
  window closed after 6 steps on capacity 16
```

There are 53 possible capacities from 9 to 61. Binary search finds the answer with six calls to the predicate.

At step three, capacity 15 fails because it needs six days. Thus the search removes 15 and each smaller capacity.

## Check the boundary

Capacity 15 does not work:

```
capacity 15, packed in arrival order
  day 1:  5  3                                load  8
  day 2:  8  2                                load 10
  day 3:  9  4                                load 13
  day 4:  7  6  1                             load 14
  day 5:  8  3                                load 11
  day 6:  5                                   load  5
  6 days against a limit of 4 -> too slow
```

Capacity 15 needs six days. Thus it does not meet the limit of four days.

Capacity 16 works:

```
capacity 16, packed in arrival order
  day 1:  5  3  8                             load 16
  day 2:  2  9  4                             load 15
  day 3:  7  6  1                             load 14
  day 4:  8  3  5                             load 16
  4 days against a limit of 4 -> feasible
```

Thus 16 is the minimum feasible capacity.

When the capacity increases from 15 to 16, the boundaries of several days change. The algorithm packs the packages again from the start. It does not change the plan for capacity 15.

## Verify the result with a full scan

```zig
/// Ask the predicate about each capacity in the range and print the answers.
///
/// The function prints one character for each capacity. Thus you can see the
/// shape of the predicate, and you do not have to assume it. A monotonic
/// predicate changes one time. Binary search cannot answer a different shape.
fn writeScan(out: *std.Io.Writer, ship: *Ship, low: u32, high: u32, pred: Predicate) !Scan {
    const before = ship.calls;
    var first_true: ?u32 = null;
    var flips: usize = 0;
    var previous = false;
    try out.print("  {d:>3} ", .{low});
    var cap = low;
    while (cap <= high) : (cap += 1) {
        const ok = pred(ship, cap);
        try out.writeByte(if (ok) '#' else '.');
        if (ok and first_true == null) first_true = cap;
        if (cap > low and ok != previous) flips += 1;
        previous = ok;
    }
    try out.print(" {d}\n", .{high});
    return .{
        .first_true = first_true,
        .flips = flips,
        .calls = ship.calls - before,
    };
}
```

*Quoted from the source: `writeScan` from `snippets/23-competitive/binary-search-answer.zig`.*

This example has only 53 possible capacities. Thus the program can also test each capacity. The program prints one character for each value:

```
every capacity from 9 to 61, '#' means feasible
    9 .......############################################## 61
  first '#' at 16, binary search said 16, agree -> true
  the predicate flips 1 time, so it is monotonic
  predicate calls: 53 scanning, 6 searching
```

A dot shows a capacity that does not work. A `#` character shows a capacity that works.

The output changes exactly one time:

```
false -> true
```

Binary search on the answer must have this property. For a small test case, a scan of the full range is a useful method to verify that the predicate is monotonic.

Here, binary search uses six calls to the predicate instead of 53. The difference is much more important when the range is large.

For example, the range of possible capacities can contain one billion values:

- A full scan can need one billion calls to the predicate.
- Binary search needs only approximately 30 calls, because each step removes approximately half of the search range. `2^30` is a little more than one billion.

Each call to the predicate reads the `n` packages one time. Thus the binary-search solution takes:

```
O(n log range)
```

A full scan takes:

```
O(n * range)
```

For a large range, a scan of each possible answer is usually too slow.

## The predicate must be monotonic

```zig
    /// The same question with a second condition: on each day, half of the
    /// hold or more must be full.
    ///
    /// This plan looks better, but the predicate is not monotonic. A big ship
    /// completes the work early and is half empty on the last day. Thus a
    /// capacity that works can fail when you add one tonne to it.
    fn feasibleAndFull(self: *Ship, cap: u32) bool {
        const days = self.daysNeeded(cap) orelse return false;
        if (days > self.limit) return false;
        var lightest: u32 = std.math.maxInt(u32);
        var load: u32 = 0;
        for (self.weights) |w| {
            if (load + w > cap) {
                lightest = @min(lightest, load);
                load = 0;
            }
            load += w;
        }
        lightest = @min(lightest, load);
        return lightest * 2 >= cap;
    }
```

*Quoted from the source: `feasibleAndFull` from `snippets/23-competitive/binary-search-answer.zig`.*

Now add a different rule: each day must also use half of the capacity of the boat or more.

This change looks small, but it removes the property that binary search needs. Now a larger capacity can make a plan fail that worked before.

For example:

```
now require every day to fill at least half the hold
    9 .......####...####....#############.................# 61
  the predicate flips 7 times, so there is no boundary
  binary search returns 31, first '#' is at 16
  feasibleAndFull(31) = true, and 8 smaller capacities pass too
```

The predicate changes between true and false many times. There is no single boundary of this form:

```
false false false ... true true true ...
```

Binary search continues to run and returns 31. Capacity 31 satisfies the predicate, but 31 is not the smallest value that satisfies it. Capacity 16 also works, and so do some other smaller values.

The binary search cannot find this problem. At each step, the search assumes that one result of the predicate lets it remove half of the range. That assumption is correct only when the predicate is monotonic.

For the original problem, the monotonic property is clear. If a capacity can ship all of the packages in the necessary number of days, a larger capacity cannot need more days. Thus when the predicate becomes true, it stays true for each larger capacity.

The half-full rule does not have this property. Before you use binary search on the answer, make sure that you can explain why the predicate is monotonic. For small test cases, you can also scan the full range and count the changes of the predicate.
