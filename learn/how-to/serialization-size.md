# Recipe: JSON vs Binary, by Size

> The same 100,000 records as JSON and as packed bytes, with exact measurements.

The program writes the same 100,000 records in two formats. With Zig's `std.json.Stringify.value`, the records take 4.62 times the bytes of a fixed 24-byte binary record that `std.mem.writeInt` writes. JSON repeats each field name, and it writes numbers as decimal text.

## The problem

You must select a wire format for a stream of records. You want a concrete number, not a guess. JSON is readable and self-describing. A packed binary layout is compact.

This recipe encodes the same 100,000 events in both formats and prints the exact byte counts. Thus you can compare measured numbers.

The data comes from a seed. Thus the sizes are reproducible. You get the same numbers on each run, and for that reason this page can assert them.

## The plan

1. Make 100,000 events from a fixed PRNG seed.
2. Serialize the slice with `std.json.Stringify.value`, and measure the text.
3. Serialize each event as a fixed 24-byte little-endian record, and measure the bytes.
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

    // Fixed seed: the data, and thus each size below, is reproducible.
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

    // JSON: the standard serializer makes the text. Then measure the text.
    var json: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(events, .{}, &json.writer);
    const json_bytes = json.written().len;

    // Binary: one little-endian record of fixed width for each event.
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

## Why binary is smaller

Here, JSON is 4.62 times larger, and the reasons come from the structure of the two formats:

- Each JSON record repeats its field names as text (`"player_id"`, `"timestamp"`). The binary form has no field names.
- Numbers become longer. A `u32` is four bytes in binary, but in JSON it is up to ten decimal digits. A float becomes a decimal string, which is usually longer than its four raw bytes.
- The enum is one byte in binary. In JSON, it becomes `"move"` or `"attack"`.

JSON pays this cost because it is self-describing.

The binary record is always 24 bytes, for all values. It contains an `i64` timestamp, a `u32` id, two `f32` coordinates, a one-byte tag and three bytes of padding.

`std.mem.writeInt` with an explicit `.little` endianness makes the bytes the same on each host. Without that endianness, the output is a copy of memory and not a format. [The binary round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/) explains this in detail.

## Speed

Speed is the other part of the decision, and binary is usually faster too. On write, binary does not format numbers as decimal text. On read, binary does not parse the numbers back.

This page does not print times, for two reasons:

- Wall-clock time is not reproducible. Thus the page cannot assert it, as it asserts each other result.
- On this site, the clock is behind the `Io` interface, because a time measurement is an effect, as I/O is.

To measure the speed yourself on a native build, put a timer around each encode loop and compare the elapsed nanoseconds. Expect the difference to become larger when the records contain more numbers.

## Variations

- **A smaller record:** remove the three bytes of padding for a 21-byte record. Or put the enum into unused bits. Do this when density is more important than alignment.
- **Compress the JSON:** gzip removes much of the difference in size, but it costs CPU time on both sides. Measure that trade-off in the same way.
- **Schema evolution:** JSON accepts new fields and absent fields. A fixed binary record does not. Thus a real binary format usually has a version byte. See [struct memory layout](https://www.ziglang.in/learn/how-to/memory-layout/) for the layout of the record.
