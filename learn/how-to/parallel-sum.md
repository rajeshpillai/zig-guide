# Recipe: Split Work Across Threads

> Divide a slice among threads with no locks and one join.

To divide work among threads in Zig, give each `std.Thread.spawn` worker its own chunk of the slice and its own output slot. Then `join` all of the threads and add the slots. Current master does not have `std.Thread.Pool`.

## The problem

You have a large slice and a computation for each element, and one core does all of the work. The usual solution is to give each thread a chunk.

The usual problem in practice is shared data. When threads write to common state, you need locks. Locks cause contention and can cause a deadlock.

This recipe gets parallel work with no locks. The threads share no data.

## The plan

1. Divide the slice into one chunk for each worker. Use ceiling division, thus the last chunk gets the remainder.
2. Give each thread its own input chunk and its own output slot. No two threads use the same data. Thus no shared mutable state needs protection.
3. `join` each thread. Then combine the slots on the main thread.

```zig
const std = @import("std");

// Each worker owns its chunk and its slot. The workers share no data. Thus
// no data needs synchronization before the join.
fn sumChunk(chunk: []const u64, slot: *u64) void {
    var sum: u64 = 0;
    for (chunk) |x| sum += x;
    slot.* = sum;
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var numbers: [1000]u64 = undefined;
    for (&numbers, 1..) |*n, i| n.* = i;

    // With a fixed number of workers, the output of this demo is the same on
    // each machine. A real program starts from std.Thread.getCpuCount().
    const workers = 4;
    var slots: [workers]u64 = undefined;
    var threads: [workers]std.Thread = undefined;

    // Use ceiling division, thus the last chunk gets the remainder.
    const chunk_size = (numbers.len + workers - 1) / workers;
    for (&threads, &slots, 0..) |*t, *slot, w| {
        const start = w * chunk_size;
        const end = @min(start + chunk_size, numbers.len);
        t.* = try std.Thread.spawn(.{}, sumChunk, .{ numbers[start..end], slot });
    }

    // join is the synchronization. After join returns, the writes of that
    // thread are visible here.
    for (threads) |t| t.join();

    var total: u64 = 0;
    for (slots) |s| total += s;
    try out.print("total: {d}\n", .{total});
    try out.print("check: {d}\n", .{@as(u64, 1000 * 1001 / 2)});

    try out.flush();
}
```

*CI builds and runs this program natively. wasm32-wasi has a single thread. Thus std.Thread.spawn does not compile for that target. (`06-cookbook.parallel-sum`)*

## Why the program needs no locks

Exactly one thread writes slot `w`. The main thread reads the slot only after `join` returns. `join` is the synchronization point. It guarantees that the writes of the joined thread are visible to the thread that called `join`.

The pattern works for each workload of the map type:

1. Divide the inputs.
2. Give each worker a private output.
3. Merge the outputs after the join.

The alternative is that each thread adds to one shared total. That needs a mutex or an atomic on the hot path. Private slots move that cost to one merge loop at the end.

## What replaced the pool

Older tutorials use `std.Thread.Pool` with a `WaitGroup`. Current master has neither of these. `std.Thread.spawn` and `join` are the primitives. The fan-out of tasks moves to the `std.Io` interface (`io.async` and `Io.Group`).

For a fixed number of workers with a long life, use spawn and join directly, as here. For structured task concurrency, see [Concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/).

## Variations

- **Thread count:** real code starts from `std.Thread.getCpuCount()`, not from a constant. The quantity of work that is useful to divide sets the maximum.
- **Work that is not equal:** chunks of equal size assume an equal cost for each element. When the items are very different, static chunks leave threads with no work. The [atomic work index](https://www.ziglang.in/learn/how-to/work-index/) recipe solves that problem.
- **False sharing:** adjacent `u64` slots can be on the same cache line. False sharing does not change correctness, and for a demo it is not important. If profiling shows that the merge pattern is hot, add padding to make each slot the size of a cache line.
