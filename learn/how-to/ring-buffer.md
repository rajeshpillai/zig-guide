# Recipe: Keeping the Last N Items

> A generic fixed-capacity ring buffer built with a type function.

## The problem

You want the most recent N things: the last few log lines for an error
report, the trailing sensor readings for a moving average, recent commands
for an undo stack. Storage must be bounded, old entries should fall off by
themselves, and ideally nothing allocates.

This is a ring buffer, and it is also the standard tour of Zig generics: a
function that takes types and comptime values, and returns a type.

## The plan

1. Write `fn LastN(comptime T: type, comptime capacity: usize) type` and
   return a struct from it. Capacity becomes part of the type, so storage
   is a plain `[capacity]T` array on the stack.
2. Keep two fields of state: `head`, the next slot to write, and `len`,
   which grows to capacity and stays there.
3. `push` writes at `head`, advances it modulo capacity, and overwrites the
   oldest entry once full. That overwrite is the feature.
4. `get(i)` addresses items oldest-first by deriving the start position
   from `head` and `len`.

```zig
const std = @import("std");

// A function that returns a type. `capacity` is baked in at compile time,
// so the storage is a plain array and nothing here allocates.
fn LastN(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0, // next slot to write
        len: usize = 0, // grows until it reaches capacity, then stays

        const Self = @This();

        // Full buffer? Overwrite the oldest. That policy is the whole
        // point of a recent-history log.
        fn push(self: *Self, item: T) void {
            self.items[self.head] = item;
            self.head = (self.head + 1) % capacity;
            if (self.len < capacity) self.len += 1;
        }

        // Index 0 is the oldest retained item. The start position is
        // derived, not stored: everything follows from head and len.
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

    // The same type function works for any element type.
    var readings: LastN(f32, 3) = .{};
    for ([_]f32{ 20.1, 20.7, 21.3, 22.9 }) |r| readings.push(r);
    try out.print("latest reading: {d:.1}\n", .{readings.get(readings.len - 1)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.ring-buffer`)*

## The type function, unpacked

`LastN([]const u8, 4)` and `LastN(f32, 3)` are two distinct, concrete types
generated at compile time. There is no boxing, no interface, and no runtime
cost for the genericity; each instantiation compiles as if written by hand.
`const Self = @This()` names the anonymous struct so methods can refer to
their own type.

Because capacity is comptime, the compiler knows every `% capacity` at
build time. For power-of-two capacities it becomes a bit mask.

## Deriving instead of storing

A common ring buffer bug is tracking both a read index and a write index
and letting them disagree. Here the oldest position is computed from `head`
and `len` on demand:

```zig
const start = (self.head + capacity - self.len) % capacity;
```

Two fields of state, one invariant, and nothing to keep in sync. The
`+ capacity` avoids underflow before the modulo; every quantity stays a
`usize`.

## Variations

- **Reject instead of overwrite:** return `error.Full` from `push` when
  `len == capacity`. Right for bounded queues, wrong for recent-history
  logs.
- **Standard library:** `std.Deque` is the allocating, growable relative:
  push and pop at both ends, no fixed capacity. This recipe's shape is what
  you write when you want bounded storage and the overwrite policy. (Older
  tutorials mention `std.RingBuffer` or `std.fifo.LinearFifo`; both are
  gone from current master.)
- **Iteration:** add an `iterator()` returning oldest-to-newest items; the
  index arithmetic is exactly `get`.
