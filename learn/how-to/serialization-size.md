# Recipe: JSON vs Binary, by Size

> The same 100,000 records as JSON and as packed bytes, measured exactly.

## The problem

You are choosing a wire format for a stream of records and want a concrete
number, not a guess. JSON is readable and self-describing; a packed binary
layout is compact. This recipe encodes the same 100,000 events both ways and
prints the exact byte counts, so the trade is a measurement rather than an
argument.

The data is seeded, so the sizes are reproducible: you get the same numbers
every run, which is also why this page can assert them.

## The plan

1. Generate 100,000 events from a fixed PRNG seed.
2. Serialize the slice with `std.json.Stringify.value` and measure the text.
3. Serialize each event as a fixed 24-byte little-endian record and measure
   the bytes.
4. Divide.

```zig
const std = @import("std");

const EventType = enum(u8) { move, attack, collect };

const GameEvent = struct {
    timestamp: i64,
    player_id: u32,
    x: f32,
    y: f32,
    event_type: EventType,
};

const num_events = 100_000;
const record_bytes = 24; // i64 + u32 + f32 + f32 + u8, padded to 24

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Fixed seed: the data, and therefore every size below, is reproducible.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const events = try gpa.alloc(GameEvent, num_events);
    for (events, 0..) |*e, i| e.* = .{
        .timestamp = @as(i64, @intCast(i)) * 1000,
        .player_id = random.int(u32),
        .x = random.float(f32) * 1000.0,
        .y = random.float(f32) * 1000.0,
        .event_type = @enumFromInt(random.int(u8) % 3),
    };

    // JSON: let the standard serializer produce the text, then measure it.
    var json: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(events, .{}, &json.writer);
    const json_bytes = json.written().len;

    // Binary: a fixed-width little-endian record per event.
    var bin: std.ArrayList(u8) = .empty;
    for (events) |e| {
        var rec: [record_bytes]u8 = @splat(0);
        std.mem.writeInt(i64, rec[0..8], e.timestamp, .little);
        std.mem.writeInt(u32, rec[8..12], e.player_id, .little);
        std.mem.writeInt(u32, rec[12..16], @bitCast(e.x), .little);
        std.mem.writeInt(u32, rec[16..20], @bitCast(e.y), .little);
        rec[20] = @intFromEnum(e.event_type);
        try bin.appendSlice(gpa, &rec);
    }
    const bin_bytes = bin.items.len;

    const ratio = @as(f64, @floatFromInt(json_bytes)) / @as(f64, @floatFromInt(bin_bytes));

    try out.print("events:       {d}\n", .{num_events});
    try out.print("json bytes:   {d}\n", .{json_bytes});
    try out.print("binary bytes: {d}\n", .{bin_bytes});
    try out.print("binary is {d:.2}x smaller\n", .{ratio});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.serialization-size`)*

## Why binary wins on size

JSON is 4.62 times larger here, and the reasons are structural. Every record
repeats its field names as text (`"player_id"`, `"timestamp"`) where the
binary form carries none. Numbers expand. A `u32` that is four bytes in binary
becomes up to ten decimal digits in JSON, and a float becomes a decimal string
that is usually longer than its four raw bytes. The enum, one byte in binary,
serializes as `"move"` or `"attack"`. None of this is waste in JSON's terms;
it is the cost of being self-describing.

The binary record is a flat 24 bytes regardless of the values: `i64`
timestamp, `u32` id, two `f32` coordinates, a one-byte tag, three bytes of
padding. `std.mem.writeInt` with an explicit `.little` endianness means the
bytes are defined, not host-dependent, which is what makes the format a format
rather than a memory dump. That discipline is the subject of [the binary
round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/).

## What about speed

Speed is the other half of the choice, and binary usually wins there too: it
skips formatting numbers into decimal on write and parsing them back on read.
This page does not print timings, for two reasons. Wall-clock time is not
reproducible, so it could not be asserted the way every snippet here is. And
on this site the clock lives behind the `Io` interface, since timing is an
effect like any other I/O. To measure it yourself on a native build, wrap each
encode loop in a timer and compare the elapsed nanoseconds. Expect the gap to
widen as the records get more numeric.

## Variations

- **Smaller still:** drop the three padding bytes for a 21-byte record, or
  bit-pack the enum into spare bits, when density matters more than alignment.
- **Compress the JSON:** gzip closes much of the size gap, at CPU cost on both
  ends; measure that trade the same way.
- **Schema evolution:** JSON tolerates added and missing fields; a fixed
  binary record does not, so a real binary format usually carries a version
  byte. See [struct memory layout](https://www.ziglang.in/learn/how-to/memory-layout/) for how the record
  is laid out.
