//! title: Time
//! Clocks moved behind the Io interface. std.time keeps the constants.

const std = @import("std");
const expect = std.testing.expect;

test "wall-clock time" {
    const io = std.testing.io;

    // .real is Unix time: nanoseconds since 1970-01-01T00:00:00Z.
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const secs = now.raw.toSeconds();

    // If this fails, the system clock is set before November 2023.
    try expect(secs > 1_700_000_000);
}

fn busyWork() u64 {
    var acc: u64 = 0;
    for (0..100_000) |i| acc +%= i *% i;
    return acc;
}

test "measure elapsed time with the monotonic clock" {
    const io = std.testing.io;

    // .awake cannot go backwards, so it is the clock to measure with.
    // .real can jump when NTP or the administrator adjusts it.
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    std.mem.doNotOptimizeAway(busyWork());
    const end = std.Io.Clock.Timestamp.now(io, .awake);

    const elapsed = start.durationTo(end);
    try expect(elapsed.raw.toNanoseconds() >= 0);
}

test "durations are values with unit conversions" {
    const d = std.Io.Duration.fromMilliseconds(1500);
    try expect(d.toMicroseconds() == 1_500_000);
    try expect(d.toSeconds() == 1); // truncates toward zero

    // Durations format as human-readable units with {f}.
    try std.testing.expectFmt("1.5s", "{f}", .{d});
    try std.testing.expectFmt("2m5s", "{f}", .{std.Io.Duration.fromSeconds(125)});
}

test "std.time still holds the constants and epoch math" {
    try expect(std.time.ns_per_s == 1_000_000_000);
    try expect(std.time.s_per_day == 86_400);

    // Calendar breakdown of a Unix timestamp, no allocation, no locale.
    const es = std.time.epoch.EpochSeconds{ .secs = 86_400 + 3_600 };
    const year_day = es.getEpochDay().calculateYearDay();
    try expect(year_day.year == 1970);

    const month_day = year_day.calculateMonthDay();
    try expect(month_day.month == .jan);
    try expect(month_day.day_index == 1); // zero-based: Jan 2nd

    try expect(es.getDaySeconds().getHoursIntoDay() == 1);
}
