# Concurrency

> async, Future, and Group, all through the Io interface.

Zig's concurrency story now runs through `std.Io`. Press Run: this executes in
your browser, on a target with **no threads at all**.

```zig
const std = @import("std");

fn slowDouble(out: *u32, value: u32) void {
    out.* = value * 2;
}

fn accumulate(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    // `Io.Mutex.lock` takes the io instance, like everything else that can
    // block. It returns an error only because it can be cancelled.
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `io.async` starts a task and hands back a Future to await.
    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(slowDouble, .{ &a, 10 });
    var second = io.async(slowDouble, .{ &b, 20 });
    first.await(io);
    second.await(io);
    try out.print("doubled: {d} {d}\n", .{ a, b });

    // `io.async` is allowed to run the task inline. `io.concurrent` is not: it
    // promises the caller can make progress meanwhile, and fails when the `Io`
    // cannot deliver that. On this single-threaded wasm target it fails, and
    // that is the whole point of the two spellings.
    var c: u32 = 0;
    if (io.concurrent(slowDouble, .{ &c, 30 })) |handle| {
        var pending = handle;
        pending.await(io);
        try out.print("concurrent: {d}\n", .{c});
    } else |err| {
        try out.print("concurrent: {s}\n", .{@errorName(err)});
    }

    // A Group awaits many tasks at once, so nothing outlives the scope.
    var total: u32 = 0;
    var mutex: std.Io.Mutex = .init;
    var group: std.Io.Group = .init;
    for (0..8) |_| {
        group.async(io, accumulate, .{ &total, &mutex, io, 1 });
    }
    try group.await(io);
    try out.print("total: {d}\n", .{total});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.concurrency`)*

## `io.async` returns a Future

```zig
var first = io.async(slowDouble, .{ &a, 10 });
var second = io.async(slowDouble, .{ &b, 20 });
first.await(io);
second.await(io);
```

The `Io` implementation decides what "async" means. A threaded implementation
runs these in parallel; the single-threaded WASI one runs them inline. **Your
code does not change**, which is exactly why this page is runnable and the
[Threads](https://www.ziglang.in/learn/standard-library/threads/) page is not.

## `async` may run it inline; `concurrent` may not

`io.async` promises only that the result is ready after you await it. It is
free to call the function immediately, finish it, and hand back a Future that
is already resolved. That is what happens on this page.

`io.concurrent` makes the stronger promise: the caller gets to keep going
while the task runs. Not every `Io` can deliver that, so it returns an error
union:

```zig
if (io.concurrent(slowDouble, .{ &c, 30 })) |handle| {
    var pending = handle;
    pending.await(io);
} else |err| {
    // error.ConcurrencyUnavailable
}
```

The snippet above prints `concurrent: ConcurrencyUnavailable`, because the
single-threaded wasm running it has no second unit of concurrency to give.
Hand the same binary an `Io.Threaded` and it prints `concurrent: 60`.

The distinction decides correctness, not performance. If a task must make
progress *before* you await it, `io.async` can deadlock. A producer that fills
a queue the same thread is about to drain will run to completion first and
block on a full queue, with nobody left to empty it. Reach for `concurrent`
there, and handle `error.ConcurrencyUnavailable` rather than `try`-ing it, or
the program stops working on exactly the targets `async` was portable across.
`Group` has both spellings too, `group.async` and `group.concurrent`, with the
same difference.

Default to `async`. It is the one that runs everywhere, including here.

## `Group` for many tasks

```zig
var group: std.Io.Group = .init;
for (0..8) |_| group.async(io, work, .{ ... });
try group.await(io);
```

A `Group` owns its tasks. Awaiting it waits for all of them, and cancelling it
cancels all of them, so a task cannot outlive the scope that started it. That
property is what "structured" means here, and it is the thing raw
`Thread.spawn` cannot give you.

## Shared state still needs a lock

Concurrency is not parallelism, but as soon as an implementation *is*
parallel, unsynchronised shared mutation is a data race. `std.Io.Mutex` is the
tool, and like everything else it takes the io instance:

```zig
try mutex.lock(io);
defer mutex.unlock(io);
```

Cancelling a `Group` cancels every member, which is the subject of the [next
chapter](https://www.ziglang.in/learn/standard-library/cancellation/).

## The bigger picture

This is the same idea as `Allocator`, applied to time instead of memory. A
function that takes an `Io` announces that it may block, and the caller
chooses the execution strategy. Libraries written this way work unchanged on a
thread pool, an event loop, or a single-threaded wasm runtime.

The rest of the machinery follows from here.
[Queues](https://www.ziglang.in/learn/standard-library/queues/) for tasks that hand work to each
other. [Select](https://www.ziglang.in/learn/standard-library/select/) for whichever finishes first.
[Locks](https://www.ziglang.in/learn/standard-library/locks/) for the shared state underneath. And
[Choosing an Io](https://www.ziglang.in/learn/standard-library/choosing-an-io/) for where the
instance comes from in the first place.
