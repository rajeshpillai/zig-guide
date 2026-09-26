# Recipe: Splitting Work Across Threads

> Divide a slice among threads with no locks and one join.

To split work across threads in Zig, give each `std.Thread.spawn` worker its
own chunk of the slice and its own output slot, then `join` them all and add
up the slots. `std.Thread.Pool` is gone from current master.

## The problem

You have a big slice and a per-element computation, and one core is doing
all the work. The usual fix is to give each thread a chunk. The part
that goes wrong in practice is sharing. As soon as threads write to common
state, you need locks. Locks bring contention and the risk of deadlock.

This recipe gets parallelism with no locks at all, by making sure the
threads share nothing.

## The plan

1. Divide the slice into one chunk per worker, ceiling-division so the
   last chunk absorbs the remainder.
2. Give each thread its own input chunk and its own output slot. No two
   threads touch the same data, so there is no shared mutable state to
   protect.
3. `join` every thread, then combine the slots on the main thread.

```zig
const std = @import("std");

// Each worker owns its chunk and its slot. Nothing is shared, so
// nothing needs to be synchronized until the join.
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

    // A fixed worker count keeps the output of this demo the same on every
    // machine. A real program would start from std.Thread.getCpuCount().
    const workers = 4;
    var slots: [workers]u64 = undefined;
    var threads: [workers]std.Thread = undefined;

    // Ceiling division so the last chunk picks up the remainder.
    const chunk_size = (numbers.len + workers - 1) / workers;
    for (&threads, &slots, 0..) |*t, *slot, w| {
        const start = w * chunk_size;
        const end = @min(start + chunk_size, numbers.len);
        t.* = try std.Thread.spawn(.{}, sumChunk, .{ numbers[start..end], slot });
    }

    // join is the synchronization: after it returns, that thread's writes
    // are visible here.
    for (threads) |t| t.join();

    var total: u64 = 0;
    for (slots) |s| total += s;
    try out.print("total: {d}\n", .{total});
    try out.print("check: {d}\n", .{@as(u64, 1000 * 1001 / 2)});

    try out.flush();
}
```

*Built and run natively by CI. wasm32-wasi is single-threaded, so std.Thread.spawn does not compile for it at all. (`06-cookbook.parallel-sum`)*

## Why no locks are needed

Slot `w` is written by exactly one thread and read only after `join`
returns. `join` is the synchronization point: it guarantees the joined
thread's writes are visible to the joiner. The pattern generalizes to any
map-style workload: partition inputs, give each worker private output,
merge after the join.

The alternative, every thread adding to one shared total, needs either a
mutex or an atomic on the hot path. Private slots move that cost to a
single merge loop at the end.

## Where the pool went

Older tutorials use `std.Thread.Pool` with a `WaitGroup`. Both are
gone from current master. `std.Thread.spawn` and `join` are the
primitives, and task-level fan-out is moving to the `std.Io` interface
(`io.async` and `Io.Group`). For a fixed number of long-lived workers,
spawn and join directly, as here. For structured task concurrency, see
[Concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/).

## Variations

- **Thread count:** real code starts from `std.Thread.getCpuCount()`
  instead of a constant, capped by the amount of work worth splitting.
- **Uneven work:** equal chunk sizes assume equal cost per element. When
  items vary a lot, static chunks leave threads idle. The
  [atomic work index](https://www.ziglang.in/learn/how-to/work-index/) recipe fixes that.
- **False sharing:** adjacent `u64` slots can share a cache line. It does
  not change correctness, and for a demo it does not matter. Pad slots to
  cache-line size if profiling shows the merge pattern hot.
