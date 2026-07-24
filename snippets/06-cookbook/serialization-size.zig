//! title: JSON vs Binary, by Size
//! The same records as text and as packed bytes, measured. Seeded, so exact.

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
