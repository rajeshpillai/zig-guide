# Queues

> Io.Queue as a bounded channel between tasks, with close and back pressure.

Tasks that only start and finish need a `Future`. Tasks that hand work to each
other while they run need a queue. `std.Io.Queue` is the bounded channel:
fixed capacity, both ends can block, and the sender can close it.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The queue owns no memory. Capacity is the buffer you hand it.
    var storage: [4]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);

    // `put` blocks when the queue is full, unless you ask for a minimum of
    // zero: then it takes what fits and tells you how much that was.
    const accepted = try queue.put(io, &.{ 1, 2, 3, 4, 5, 6 }, 0);
    try out.print("accepted {d} of 6\n", .{accepted});

    // Closing says there will be no more. Anything already buffered is still
    // delivered before the receiver is told.
    queue.close(io);

    var total: u32 = 0;
    while (queue.getOne(io)) |value| {
        total += value;
    } else |err| {
        try out.print("drained {d}, then {s}\n", .{ total, @errorName(err) });
    }

    // A closed queue refuses new elements even though the buffer is empty now.
    queue.putOne(io, 7) catch |err| {
        try out.print("put after close: {s}\n", .{@errorName(err)});
    };

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.queues`)*

## Capacity is a buffer you supply

```zig
var storage: [4]u32 = undefined;
var queue: std.Io.Queue(u32) = .init(&storage);
```

The queue allocates nothing. It is a ring over the array you give it, so its
capacity, its lifetime and where it lives are all yours to decide, the same
deal `Io.Writer` offers. A queue on the stack of the function that spawns both
tasks is the common case.

## `put` and `get` take a minimum

```zig
const accepted = try queue.put(io, &.{ 1, 2, 3, 4, 5, 6 }, 0);
```

The last argument is how many elements the call must move before it may
return. `putAll` and `putOne` are the everything-or-block spellings. A minimum
of zero is the one that never blocks: it moves what fits and returns the
count, which is 4 above because that is the capacity. `get` mirrors it
exactly.

That parameter is what makes batching cheap. A consumer that asks for a
minimum of one and offers a buffer of 64 gets everything currently queued in a
single call. It blocks only when there is nothing at all.

## Closing is how the receiver learns to stop

```zig
queue.close(io);
```

A closed queue rejects new elements immediately, but delivers everything
already buffered before it reports `error.Closed`. So the drain loop reads
until the error and knows it has lost nothing:

```zig
while (queue.getOne(io)) |value| {
    total += value;
} else |err| { ... }
```

The consumer never has to be told how many elements are coming, which is the
detail that lets a producer decide as it goes.

## Back pressure between two tasks

```zig
const std = @import("std");

/// Fills the queue and closes it. Capacity is two, so this blocks partway
/// through and resumes as the consumer drains: back pressure, for free.
fn produce(io: std.Io, queue: *std.Io.Queue(u32)) void {
    for (1..6) |i| {
        queue.putOne(io, @intCast(i)) catch return;
    }
    queue.close(io);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    var storage: [2]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);

    var producer = try io.concurrent(produce, .{ io, &queue });
    defer producer.await(io);

    // The consumer never asks how many are coming. It reads until the sender
    // closes, which is the whole reason `error.Closed` exists.
    while (queue.getOne(io)) |value| {
        try out.print("got {d}\n", .{value});
    } else |err| {
        try out.print("sender is done: {s}\n", .{@errorName(err)});
    }

    try out.flush();
}
```

*Built and run natively by CI. The producer has to make progress while the consumer waits, which is io.concurrent, and single-threaded wasm has none to give. (`03-standard-library.queue-worker`)*

With a capacity of two and five elements to send, the producer blocks partway
through and resumes as the consumer drains. Nothing coordinates that: a full
queue blocking the sender *is* the back pressure, and the pair self-regulates
at the speed of the slower side.

This is the case that needs
[`io.concurrent`](https://www.ziglang.in/learn/standard-library/concurrency/) rather than
`io.async`. A producer started with `async` may run inline, all the way to the
point where it fills the queue and blocks. The consumer that would drain it is
still waiting for `async` to return. That deadlock is the reason the two
spellings exist, and it is why this snippet is native and the one at the top
of the page is not.

## Cancellation

Every blocking call here is a cancellation point: `put`, `get`, and their
`One` and `All` forms return `Cancelable` errors, and the `Uncancelable`
variants opt out for cleanup paths. See
[Cancellation](https://www.ziglang.in/learn/standard-library/cancellation/); the rule that
`error.Canceled` should propagate applies to a blocked producer as much as
anywhere else.
