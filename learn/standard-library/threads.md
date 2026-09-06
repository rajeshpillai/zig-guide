# Threads

> Real OS threads, and why this page cannot run in your browser.

```zig
const std = @import("std");

fn addTo(total: *u32, amount: u32) void {
    total.* += amount;
}

fn addLocked(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // One thread, joined explicitly.
    var value: u32 = 0;
    const thread = try std.Thread.spawn(.{}, addTo, .{ &value, 42 });
    thread.join();
    try out.print("single: {d}\n", .{value});

    // Many threads touching one variable need synchronisation; without the
    // mutex this is a data race and the total is unreliable.
    var total: u32 = 0;
    var mutex: std.Io.Mutex = .init;
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, addLocked, .{ &total, &mutex, io, 1 });
    }
    for (threads) |t| t.join();
    try out.print("locked total: {d}\n", .{total});

    // Atomics cover the simple counter case without a lock.
    var counter = std.atomic.Value(u32).init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    try out.print("atomic: {d}\n", .{counter.load(.monotonic)});

    try out.flush();
}
```

*Built and run natively by CI. wasm32-wasi is single-threaded, so std.Thread.spawn does not compile for it at all. (`03-standard-library.threads`)*

## Spawn and join

```zig
const thread = try std.Thread.spawn(.{}, function, .{ args... });
thread.join();
```

The arguments are a tuple, matching the function's parameters. `join` blocks
until the thread finishes; `detach` gives up the handle instead.

Every spawned thread must be joined or detached. A handle dropped without
either leaks the thread's resources, and there is no destructor to catch it.
So the `defer thread.join()` goes on the line after the spawn, for the same
reason a `defer free` goes after an allocation.

Two threads writing the same memory without synchronisation is a data race. A
data race is undefined behaviour rather than a wrong answer: the optimiser is
entitled to assume it does not happen.

## Synchronisation moved to `std.Io`

This is the part that breaks older code. `std.Thread.Mutex` no longer exists.
It is `std.Io.Mutex` now, and `lock` takes the io instance:

```zig
var mutex: std.Io.Mutex = .init;
try mutex.lock(io);
defer mutex.unlock(io);
```

`lock` can fail only because it can be *cancelled*, which is what makes it
composable with the rest of the `Io` machinery. See
[Cancellation](https://www.ziglang.in/learn/standard-library/cancellation/) for what that means.

The move is not cosmetic. A mutex that knows about the `Io` instance can be
built differently depending on how the program is running. A real futex under
an OS thread pool. A simple flag when everything is on one thread. A yield to
the scheduler under green threads. Code written against `std.Io.Mutex` works
under all three without changing.

The rule for using one is unchanged, and still the hard part. Every access to
the shared data, read or write, has to hold the lock. And the lock has to be
released on every path out. `defer` handles the second. Nothing handles the
first except discipline, which is why the smallest possible amount of shared
state is the design to aim for.

## Atomics for the simple cases

A counter does not need a mutex:

```zig
var counter = std.atomic.Value(u32).init(0);
_ = counter.fetchAdd(1, .monotonic);
```

Note the `_ =`: `fetchAdd` returns the previous value, and Zig will not let
you drop it silently.

The memory ordering argument is the part to be careful with. `.monotonic` says
the operation itself is atomic and promises nothing about how it orders
against other memory. That is exactly right for a counter nobody reads until
the end, and wrong for a flag that publishes data written before it. When one
thread writes data and then sets a flag, and another reads the flag and then
the data, the pair needs `.release` and `.acquire`. When in doubt `.seq_cst`
is the conservative choice and the slow one.

## Prefer structured concurrency

For most work, [`Io.async` and
`Io.Group`](https://www.ziglang.in/learn/standard-library/concurrency/) are a better fit than
spawning raw threads. They are cancellable, they cannot leak a running task
past their scope, and they work on targets that have no threads at all,
including the one this site runs on.

The general point is that a thread is a low-level resource, like a raw
allocation. Most code wants "run these things concurrently and wait for them",
which is a scope with a lifetime, not a handle to manage. Reach for
`std.Thread.spawn` when you genuinely want a long-lived worker with its own
loop, and for the structured forms otherwise.
