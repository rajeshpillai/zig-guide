//! title: Binary Search on the Answer
//! The search space is a range of possible answers, not an array. The
//! predicate is a greedy pack, and the bounds come from the input. The program
//! prints the window as it closes and the boundary that the search finds. Then
//! it prints a full scan that must agree with the search. Last, it uses a
//! predicate that changes many times, and the same loop returns a wrong number.

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
