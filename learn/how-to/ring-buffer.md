# Recipe: Keep the Last N Items

> A generic ring buffer with a fixed capacity, built with a type function.

In Zig, a ring buffer can be a type function: `fn LastN(comptime T: type, comptime capacity: usize) type`. The function returns a struct that holds a fixed `[capacity]T` array. When the buffer is full, a push writes over the oldest item. No code allocates memory.

## The problem

You want the N most recent items. Some examples:

- the last log lines for an error report
- the last sensor readings for a moving average
- the recent commands for an undo stack

The storage must have a limit. Old entries must go away automatically, and if possible, no code allocates.

This is a ring buffer. A ring buffer is also a good first example of Zig generics: a function that takes types and comptime values, and returns a type.

## The plan

1. Write `LastN`, and return a struct from it. The capacity becomes part of the type. Thus the array can be on the stack.
2. Keep two fields of state. `head` is the next slot to write. `len` increases to the capacity and then stays there.
3. `push` writes at `head` and moves `head` forward, modulo the capacity. When the buffer is full, `push` writes over the oldest entry. This overwrite is intentional.
4. `get(i)` gets items with the oldest first. It calculates the start position from `head` and `len`.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.ring-buffer`)*

## The type function in detail

`LastN([]const u8, 4)` and `LastN(f32, 3)` are two different concrete types. The compiler makes them at compile time. The generic code needs no boxing, no interface and no cost at runtime. Each instance compiles as if you wrote it by hand.

`const Self = @This()` gives a name to the anonymous struct. Thus the methods can refer to their own type.

The capacity is comptime. Thus the compiler knows each `% capacity` at build time. For a capacity that is a power of two, the modulo becomes a bit mask.

## Calculate, do not store

A common bug in a ring buffer is to keep a read index and a write index that do not agree. Here, the code calculates the oldest position from `head` and `len` when it needs the position:

```zig
const start = (self.head + capacity - self.len) % capacity;
```

The buffer has two fields of state and one invariant. Thus no two indexes can disagree. The `+ capacity` prevents underflow before the modulo. Each quantity stays a `usize`.

## Variations

- **Refuse, do not overwrite:** return `error.Full` from `push` when `len == capacity`. This is correct for bounded queues, but not for logs of recent history.
- **Standard library:** `std.Deque` is the related type that allocates and can grow. It can push and pop at both ends, and it has no fixed capacity. Write the shape of this recipe when you want bounded storage and the overwrite policy. (Older tutorials refer to `std.RingBuffer` or `std.fifo.LinearFifo`. Current master has neither of them.)
- **Iteration:** add an `iterator()` that returns the items from the oldest to the newest. It uses the same index arithmetic as `get`.
