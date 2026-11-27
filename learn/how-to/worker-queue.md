# Recipe: A Producer/Consumer Queue

> std.Io.Queue as a bounded channel, with close() as the shutdown protocol.

A producer/consumer queue in Zig is `std.Io.Queue(T)`. Workers block on `getOne`. After the producer calls `close`, the workers get the items that remain, and then they get `error.Closed`.

## The problem

One part of your program finds work. A different part does the work. The usual solution is a queue between the two parts.

Versions that people write by hand usually get extra parts: a mutex, a condition variable and a "no more work" flag. They also often get a subtle bug: at shutdown, workers wait forever.

On current Zig master, `std.Io.Queue(T)` does all of this. It is a bounded, thread-safe channel. It has a put and a get that block, and a close protocol.

## The plan

1. Make a `std.Io.Queue(u64)` on a fixed buffer that you supply. The length of the buffer is the capacity of the queue. If a producer is more items ahead than the capacity, the producer blocks until the workers take more items. The name of this behavior is backpressure.
2. Spawn workers that loop on `getOne`. `getOne` blocks until an item arrives.
3. Produce the items, then call `close`. The workers get the items that remain. Then `getOne` returns `error.Closed`, and each worker stops its loop.
4. `join` the workers.

```zig
const std = @import("std");

const Queue = std.Io.Queue(u64);

fn consumer(q: *Queue, io: std.Io, total: *std.atomic.Value(u64)) void {
    while (true) {
        // Blocks until an item arrives. After close(), the queue still delivers
        // the items that remain. Only then does getOne return Closed.
        const job = q.getOne(io) catch return;
        _ = total.fetchAdd(job * job, .monotonic);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The queue borrows its storage: eight slots. If a producer is more than
    // eight items ahead, the producer blocks. This backpressure prevents an
    // overload of slow workers by a fast producer.
    var storage: [8]u64 = undefined;
    var queue: Queue = .init(&storage);

    var total = std.atomic.Value(u64).init(0);
    var workers: [3]std.Thread = undefined;
    for (&workers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ &queue, io, &total });
    }

    // Produce twenty jobs, then close the queue. The close tells the workers
    // to stop. It needs no sentinel values and no stop flag, and no worker
    // leaks.
    for (1..21) |job| try queue.putAll(io, &.{job});
    queue.close(io);

    for (workers) |t| t.join();
    try out.print("processed total: {d}\n", .{total.load(.monotonic)});

    try out.flush();
}
```

*CI builds and runs this program natively. wasm32-wasi has a single thread. Thus std.Thread.spawn does not compile for that target. (`06-cookbook.worker-queue`)*

## Close is the shutdown protocol

Shutdown is the usual place where worker queues fail. Usual solutions are a sentinel value for each worker, or a flag and a broadcast. It is easy to make an error in each of these.

`close` makes shutdown part of the contract of the queue:

1. A put after close fails.
2. The queue still delivers the items that it already has.
3. Only then does a get return `error.Closed`.

Thus the worker loop is two lines with no special cases, and no worker can wait through the shutdown.

## Why the queue takes `io`

Each operation that blocks goes through the `std.Io` interface, and the queue does too. The rest of the standard library now follows the same design.

The code that supplies the `Io` implementation decides how a block works: with OS threads here, or with an event loop in a different program. Operations that block also become cancellation points. When you give `io` to the worker, the same worker code works across different execution models.

## Variations

- **Batching:** `put` and `get` move slices, not only single items. They return the number of items that they moved. `putAll` blocks until all of the items are in the queue. Batches divide the cost of synchronization across many items.
- **More than one producer:** put is thread-safe. Thus many producers can put items into one queue. Close the queue one time, from the coordinator that knows when production is complete.
- **A channel for results:** for a full pipeline, give the workers a second queue for their results. Close that queue after the `join` of the workers.
