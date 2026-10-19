//! title: Keep the Last N Items
//! A generic ring buffer: a type function, an index that wraps, no allocator.

const std = @import("std");

// A function that returns a type. `capacity` is fixed at compile time.
// Thus the storage is a plain array, and no code here allocates.
fn LastN(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0, // next slot to write
        len: usize = 0, // increases to capacity, then stays at capacity

        const Self = @This();

        // If the buffer is full, write over the oldest item. A log of recent
        // history needs exactly this policy.
        fn push(self: *Self, item: T) void {
            self.items[self.head] = item;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) self.len += 1;
        }

        // Index 0 is the oldest item that the buffer keeps. The code
        // calculates the start position from head and len. It does not store it.
        fn get(self: *const Self, i: usize) T {
            std.debug.assert(i < self.len);
            const start = (self.head + capacity - self.len) % capacity;
            return self.items[(start + i) % capacity];
        }
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Keep the last four log lines of a longer stream.
    var recent: LastN([]const u8, 4) = .{};

    const stream = [_][]const u8{
        "connect",  "auth ok",   "read 512", "read 1024",
        "read 256", "timeout",   "retry",
    };
    for (stream) |line| recent.push(line);

    try out.print("saw {d} events, kept {d}:\n", .{ stream.len, recent.len });
    for (0..recent.len) |i| {
        try out.print("  [{d}] {s}\n", .{ i, recent.get(i) });
    }

    // The same type function works for all element types.
    var readings: LastN(f32, 3) = .{};
    for ([_]f32{ 20.1, 20.7, 21.3, 22.9 }) |r| readings.push(r);
    try out.print("latest reading: {d:.1}\n", .{readings.get(readings.len - 1)});

    try out.flush();
}
