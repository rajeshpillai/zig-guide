# Async, Future and Group

> async, Future, and Group, all through the Io interface.

Concurrency in Zig now goes through `std.Io`.
[The Io Interface](https://www.ziglang.in/learn/standard-library/io-interface/) explains that
interface, and this section expects you to know it. Each chapter here takes an
`Io` and gives it to the functions that it calls.

Press Run. The program runs in your browser, on a target with **no threads**.

```zig
const std = @import("std");

fn slowDouble(out: *u32, value: u32) void {
    out.* = value * 2;
}

fn accumulate(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    // `Io.Mutex.lock` takes the io instance, like all other functions that can
    // block. It returns an error for one reason only: a task can cancel it.
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `io.async` starts a task and returns a Future to await.
    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(slowDouble, .{ &a, 10 });
    var second = io.async(slowDouble, .{ &b, 20 });
    first.await(io);
    second.await(io);
    try out.print("doubled: {d} {d}\n", .{ a, b });

    // `io.async` can run the task inline. `io.concurrent` cannot: it promises
    // that the caller can continue while the task runs. It fails when the `Io`
    // cannot keep that promise. On this single-threaded wasm target, it fails.
    // This difference is the reason for two functions.
    var c: u32 = 0;
    if (io.concurrent(slowDouble, .{ &c, 30 })) |handle| {
        var pending = handle;
        pending.await(io);
        try out.print("concurrent: {d}\n", .{c});
    } else |err| {
        try out.print("concurrent: {s}\n", .{@errorName(err)});
    }

    // A Group awaits many tasks together. Thus no task continues after the scope.
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

The `Io` implementation decides the meaning of "async". A threaded
implementation runs these calls in parallel. The single-threaded WASI
implementation runs them inline. **Your code does not change.** For this
reason, you can run this page, and you cannot run the
[Threads](https://www.ziglang.in/learn/concurrency/threads/) page.

## `async` can run a task inline, and `concurrent` cannot

`io.async` promises only one thing: the result is ready after you await it.
`io.async` can call the function immediately, complete it, and return a Future
that is already resolved. On this page, that occurs.

`io.concurrent` makes a stronger promise: the caller continues while the task
runs. Not all `Io` implementations can keep that promise. Thus
`io.concurrent` returns an error union:

```zig
if (io.concurrent(slowDouble, .{ &c, 30 })) |handle| {
    var pending = handle;
    pending.await(io);
} else |err| {
    // error.ConcurrencyUnavailable
}
```

The snippet above prints `concurrent: ConcurrencyUnavailable`. The
single-threaded wasm that runs the snippet has no second unit of concurrency
to give. If you give the same binary an `Io.Threaded`, it prints
`concurrent: 60`.

The difference has an effect on correctness, not on performance. If a task
must make progress *before* you await it, `io.async` can deadlock. For
example, a producer fills a queue, and the same thread must empty the queue
later. The producer runs first until it stops on a full queue. Then no code is
available to empty the queue.

For that case, do these steps:

- Use `concurrent`.
- Handle `error.ConcurrencyUnavailable`. Do not use `try` on it. If you use
  `try`, the program fails on the single-threaded targets, where `async`
  still works.

`Group` also has the two forms, `group.async` and `group.concurrent`, with the
same difference.

Use `async` as the default. `async` runs on all targets, and this page is one
of them.

## `Group` for many tasks

```zig
var group: std.Io.Group = .init;
for (0..8) |_| group.async(io, work, .{ ... });
try group.await(io);
```

A `Group` owns its tasks. When you await the group, it waits for all of the
tasks. When you cancel the group, it cancels all of the tasks. Thus a task
cannot continue after the end of the scope that started it. That property is
the meaning of "structured" here. A raw `Thread.spawn` does not give you this
property.

## Shared state still needs a lock

Concurrency is not parallelism. But when an implementation *is* parallel, a
change to shared data without synchronisation is a data race. Use
`std.Io.Mutex` for this. Like the other tools, it takes the io instance:

```zig
try mutex.lock(io);
defer mutex.unlock(io);
```

When you cancel a `Group`, it cancels each member. The [next
chapter](https://www.ziglang.in/learn/concurrency/cancellation/) is about cancellation.

## How `Io` compares to `Allocator`

`Io` works in the same way as `Allocator`:

- A function that takes an `Allocator` lets the caller select the source of
  the memory.
- A function that takes an `Io` tells you that it can block. The caller
  selects how the function runs.

A library that uses `Io` in this way works without a change. It works on a
thread pool, an event loop, or a single-threaded wasm runtime.

The other chapters in this section use this design:

- [Queues](https://www.ziglang.in/learn/concurrency/queues/) is for tasks that give work to other
  tasks.
- [Select](https://www.ziglang.in/learn/concurrency/select/) is for the task that completes first.
- [Locks](https://www.ziglang.in/learn/concurrency/locks/) is for the shared state below the tasks.
- [Choose an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) shows where the `Io`
  instance comes from.
