# Binary Search on the Answer

> Searching a range of possible answers instead of an array, with a greedy pack as the predicate and a brute-force scan checking the boundary.

A shipping company has a list of packages that must be loaded onto a boat in the same order they arrive. The goal is to ship all the packages within four days.

We need to find the minimum boat capacity required.

This value does not appear directly in the input, so there is no sorted array that we can search.

But for any given capacity, we can ask a simple question:

Can all packages be shipped within four days using this capacity?

For example, a capacity of 9 tonnes is not enough. A capacity of 61 tonnes is enough.

Also, if a capacity works, every larger capacity will work.

So the results look like this:

```
no no no no ... yes yes yes yes ...
```

There is one point where the answer changes from `no` to `yes`.

We can use binary search to find that point.

```zig
const std = @import("std");

/// The problem: package weights in loading order, then the number of days.
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

/// The ship, the deadline, and a count of how often the question was asked.
///
/// Packages are loaded in the order they arrive, so a capacity fixes the whole
/// plan. Fill today until the next package would overflow the hold, then start
/// tomorrow. `calls` counts every predicate call so the two searches below can
/// be priced against each other.
const Ship = struct {
    weights: []const u32,
    limit: u32,
    calls: usize = 0,

    /// Days needed at this capacity, or null when some package cannot be loaded.
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

    /// Does this capacity finish on time?
    ///
    /// False below the boundary and true at or above it, with one flip in
    /// between. Nothing else in this file is allowed to assume that; the run
    /// below checks it.
    fn feasible(self: *Ship, cap: u32) bool {
        const days = self.daysNeeded(cap) orelse return false;
        return days <= self.limit;
    }

    /// The same question with a second condition bolted on: no day may leave
    /// more than half the hold empty.
    ///
    /// It sounds like a tidier plan and it is not monotonic. A big ship
    /// finishes early and sails half empty on the last day, so a capacity that
    /// works can stop working when you add one tonne to it.
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

/// First capacity in `[low, high]` that the predicate accepts.
///
/// The loop is the one from the binary search chapter with the array taken
/// out. `items[mid] < key` becomes `!pred(mid)`: mid is too small to be the
/// answer, so `lo = mid + 1` discards it. The other branch leaves mid a
/// candidate and keeps it. When the window empties, `lo` is the boundary.
fn firstFeasible(ship: *Ship, low: u32, high: u32, pred: Predicate) u32 {
    var lo = low;
    var hi = high;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pred(ship, mid)) hi = mid else lo = mid + 1;
    }
    return lo;
}

/// The same walk with a row printed per step.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run checks that the two return the same capacity.
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

/// One day of the plan: the packages loaded, then the tonnage.
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

/// Run the greedy pack at one capacity and print the plan it produces.
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

/// What an exhaustive scan of the range found.
const Scan = struct {
    first_true: ?u32,
    flips: usize,
    calls: usize,
};

/// Ask the predicate about every capacity in the range and draw the answers.
///
/// One character per capacity, so the shape of the predicate is visible rather
/// than assumed. A monotonic predicate flips once. Anything else is not a
/// question binary search can answer.
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

    // The bounds. Nothing under the heaviest package can hold it, and one day
    // at the total always works, so the boundary is somewhere in between.
    try out.print("search range: [{d}, {d}], {d} candidates\n\n", .{
        heaviest,
        total,
        total - heaviest + 1,
    });

    // What one predicate call actually does.
    try writePacking(out, &ship, heaviest + (total - heaviest) / 2);

    ship.calls = 0;
    try out.writeAll("binary search over the capacities\n");
    const answer = try traceFirstFeasible(out, &ship, heaviest, total);
    const search_calls = ship.calls;
    try out.print("  plain firstFeasible agrees -> {}\n\n", .{
        answer == firstFeasible(&ship, heaviest, total, Ship.feasible),
    });

    // The two packings either side of the boundary are the whole claim.
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

    // Move a bound and the search still returns a number.
    const average = total / ship.limit;
    const bad = firstFeasible(&ship, heaviest, average, Ship.feasible);
    try out.print("with the high bound set to total / days = {d}\n", .{average});
    try out.print("  the search returns {d} and feasible({d}) = {s}\n", .{
        bad,
        bad,
        if (ship.feasible(bad)) "yes" else "no",
    });
    try out.print("  {d} days needed there, limit {d}\n\n", .{ ship.daysNeeded(bad).?, ship.limit });

    // A predicate that flickers. The loop terminates, returns a capacity, and
    // that capacity is not the smallest one the predicate accepts.
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

<SnippetSource name="23-competitive.binary-search-answer" decl="feasible" />

The packages must be loaded in arrival order.

For a given capacity, we keep adding packages to the current day's load. If the next package does not fit, we start a new day.

There are no other choices to make. The same capacity will always produce the same number of days for the same package list.

`daysNeeded` returns null when a single package is heavier than the given capacity.

That capacity can never work because the package cannot be loaded at all.

`feasible` therefore treats null as `false`.

<SnippetSource name="23-competitive.binary-search-answer" decl="daysNeeded" />

For example:

```
capacity 35, packed in arrival order
  day 1:  5  3  8  2  9  4                    load 31
  day 2:  7  6  1  8  3  5                    load 30
  2 days against a limit of 4 -> feasible
```

A capacity of 35 finishes in two days, so it is feasible.

The binary search does not need to know that it took exactly two days. It only needs the result:

```
true
```

Each call to `feasible` checks the package list once. This is the `n` part of the final time complexity.

## Choosing the lower and upper bounds

The lower bound is the weight of the heaviest package.

The heaviest package weighs 9 tonnes, so the boat must have a capacity of at least 9.

There is no reason to test anything below 9.

The upper bound is the total weight of all packages.

The total is 61 tonnes. With a capacity of 61, every package can be loaded in one day.

So the answer must be somewhere between 9 and 61.

These bounds come directly from the input. They continue to work even when the package weights change.

Using a guessed bound can make the binary search return the wrong answer.

For example, using the average load per day as the upper bound is incorrect:

```
with the high bound set to total / days = 15
  the search returns 15 and feasible(15) = no
  6 days needed there, limit 4
```

The binary search still returns 15 because that is the highest value available inside the search range.

The loop itself did nothing wrong. The search range was wrong.

There was no feasible value inside that range.

This is why it is useful to check the result after the search.

The returned answer should be feasible.

The value immediately below it should not be feasible.

## Binary search using a predicate

<SnippetSource name="23-competitive.binary-search-answer" decl="firstFeasible" />

[Binary Search](https://www.ziglang.in/learn/competitive-programming/binary-search/) explains the half-open search window and the invariant used by this loop.

The main difference here is the comparison.

In a normal lower-bound search, we may write something like:

`items[mid] < key`

This means `mid` is too small, so we move the lower bound to:

`mid + 1`

Here we use:

`!pred(ship, mid)`

If the predicate returns false, that capacity is too small.

So we again move to:

`mid + 1`

If the predicate returns true, `mid` may be the answer, so we keep it inside the search range.

The binary search structure is the same. Instead of reading a value from an array, we call a function that tells us whether the current value works.

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

There are 53 possible capacities from 9 to 61.

Binary search finds the answer using six predicate calls.

At step three, capacity 15 fails because it needs six days.

Therefore 15 and every smaller capacity can be removed from the search.

## Checking the boundary

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

It needs six days, so it misses the four-day deadline.

Capacity 16 works:

```
capacity 16, packed in arrival order
  day 1:  5  3  8                             load 16
  day 2:  2  9  4                             load 15
  day 3:  7  6  1                             load 14
  day 4:  8  3  5                             load 16
  4 days against a limit of 4 -> feasible
```

So 16 is the minimum feasible capacity.

Notice that increasing the capacity from 15 to 16 changes several day boundaries.

The algorithm packs the packages again from the beginning. It does not modify the packing produced for capacity 15.

## Verify the result with a full scan

<SnippetSource name="23-competitive.binary-search-answer" decl="writeScan" />

This example has only 53 possible capacities, so we can also test every capacity.

The program prints one character for each value:

```
every capacity from 9 to 61, '#' means feasible
    9 .......############################################## 61
  first '#' at 16, binary search said 16, agree -> true
  the predicate flips 1 time, so it is monotonic
  predicate calls: 53 scanning, 6 searching
```

The dots represent capacities that do not work.

The `#` characters represent capacities that work.

The output changes exactly once:

```
false -> true
```

This is the property required for binary search on the answer.

For a small test case, scanning the whole range is a useful way to verify that the predicate is monotonic.

Here binary search uses six predicate calls instead of 53.

The difference becomes much more important when the range is large.

Suppose the possible capacity range contains one billion values.

A full scan could require one billion predicate calls.

Binary search needs only about 30 calls because the search range is divided roughly in half each time. `2^30` is slightly more than one billion.

Each predicate call scans the `n` packages once.

So the binary-search solution takes:

```
O(n log range)
```

A full scan takes:

```
O(n * range)
```

For large ranges, scanning every possible answer is usually too slow.

## The predicate must be monotonic

<SnippetSource name="23-competitive.binary-search-answer" decl="feasibleAndFull" />

Now consider another rule.

Suppose every day must also use at least half of the boat's capacity.

This may sound like a small change, but it breaks the property required by binary search.

Increasing the boat capacity can now make a previously valid plan invalid.

For example:

```
now require every day to fill at least half the hold
    9 .......####...####....#############.................# 61
  the predicate flips 7 times, so there is no boundary
  binary search returns 31, first '#' is at 16
  feasibleAndFull(31) = true, and 8 smaller capacities pass too
```

The predicate changes between true and false several times.

There is no single boundary of the form:

```
false false false ... true true true ...
```

Binary search still runs and returns 31.

Capacity 31 satisfies the predicate, but it is not the smallest value that does.

Capacity 16 also works, along with several other smaller values.

The binary search cannot detect this problem.

At every step it assumes that one predicate result allows half of the remaining range to be discarded.

That assumption is only valid when the predicate is monotonic.

For the original shipping problem, the monotonic property is clear.

If a capacity can ship all packages within the required number of days, increasing that capacity cannot require more days.

So once the predicate becomes true, it stays true for every larger capacity.

The half-full rule does not have this property.

Before using binary search on the answer, make sure you can explain why the predicate is monotonic.

For small test cases, you can also scan the complete range and check how many times the predicate changes.
