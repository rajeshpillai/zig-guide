# Time

> Clocks behind the Io interface; constants and calendars in std.time.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.time`)*

## Reading a clock takes an Io

Reading the clock is an I/O operation now, so it goes through the same `Io`
interface as files and sockets: `std.Io.Clock.Timestamp.now(io, clock)`. In a
test the instance is `std.testing.io`; in a program it is `init.io`. This is
the writergate-era pattern applied to time. The older `std.time.timestamp` and
`std.time.milliTimestamp` free functions are gone.

## Pick the right clock

- `.real` is wall-clock Unix time: nanoseconds since 1970. Use it for
  timestamps you store or show. It can jump backward when NTP or an
  administrator corrects it.
- `.awake` is monotonic: it never goes backward. Use it to measure how long
  something took. Subtracting two `.real` readings around a slow operation can
  give a negative or absurd result if the clock was adjusted in between.

`durationTo` between two timestamps gives an `Io.Duration`.

## Durations are values

`Io.Duration` carries a nanosecond count with conversion helpers
(`fromMilliseconds`, `toSeconds`, and so on) that truncate toward zero.
Formatted with `{f}` it prints human units: `1.5s`, `2m5s`.

## std.time keeps the arithmetic

The constants (`ns_per_s`, `s_per_day`, and the rest) and the calendar code
still live in `std.time`, no `Io` required, because they are pure math.
`std.time.epoch` breaks a Unix timestamp into year, month, day, and
time-of-day without allocating or consulting a locale. Note the day index is
zero-based: day 1 is the second of the month.

Using the named constants rather than writing `1_000_000_000` is worth the
habit. `ns_per_s` reads as what it is, and an expression like `5 *
std.time.ns_per_min` cannot be off by a factor of a thousand in a way review
would miss.

## Measuring how long something took

```zig
const start = try std.Io.Clock.Timestamp.now(io, .awake);
doWork();
const elapsed = start.durationTo(try std.Io.Clock.Timestamp.now(io, .awake));
```

`.awake` for this, always. The whole reason the two clocks are separate is
that `.real` can be moved by NTP or by an administrator between your two
readings. A benchmark that occasionally reports a negative duration is worse
than no benchmark.

For a one-off measurement that is fine. For anything you intend to draw a
conclusion from, one reading is noise. Run the work enough times that the
total is comfortably larger than the clock's resolution, then report the total
divided by the count.

## Timezones and formatting

`std.time.epoch` gives you UTC. There is no timezone database in the standard
library and no locale-aware date formatting. Same reason as the missing
Unicode case folding: the tables change several times a year, and they do not
belong frozen inside every binary.

So the practical advice is the boring one that is right anyway. Store and
transmit `.real` timestamps as integers, in UTC. Convert to local time and to
a human-readable string at the edge, with a library, only where a person will
read it. A program that keeps UTC internally has no daylight-saving bugs to
have.

## Waiting

Sleeping goes through the `Io` instance too, which is what makes it
cancellable and what lets the same code work under threads and under an
evented runtime. A raw sleep that blocks the thread is the thing the interface
exists to avoid; see [cancellation](https://www.ziglang.in/learn/standard-library/cancellation/) for
what a timeout that can be interrupted looks like.
