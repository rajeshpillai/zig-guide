# Choosing an Io

> Threaded, the evented implementations, and building one yourself.

Every other chapter in this run takes `init.io` and passes it down. This one
looks at where that value comes from, because the choice belongs to the
program and it is the only place in the codebase that has to make it.

```zig
const std = @import("std");

fn double(value: u32) u32 {
    return value * 2;
}

/// Ordinary library code. It never names an implementation, so it works with
/// whichever one the caller built.
fn run(io: std.Io, label: []const u8, out: *std.Io.Writer) !void {
    var future = io.async(double, .{21});
    try out.print("{s}: async {d}", .{ label, future.await(io) });

    if (io.concurrent(double, .{21})) |handle| {
        var pending = handle;
        try out.print(", concurrent {d}\n", .{pending.await(io)});
    } else |err| {
        try out.print(", concurrent {s}\n", .{@errorName(err)});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // A thread pool. The allocator is only used to spawn tasks; everything
    // else in the implementation is allocation-free.
    var pool: std.Io.Threaded = .init(init.gpa, .{});
    defer pool.deinit();
    try run(pool.io(), "threaded", out);

    // The same implementation with concurrency turned off. `async` still works
    // because it is allowed to run the task inline; `concurrent` cannot.
    var capped: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .nothing });
    defer capped.deinit();
    try run(capped.io(), "capped", out);

    // A statically initialised instance that spawns nothing at all. This is
    // what a target without threads gets, and it needs no allocator.
    var lone: std.Io.Threaded = .init_single_threaded;
    try run(lone.io(), "single-threaded", out);

    try out.flush();
}
```

*Built and run natively by CI. The point is the difference between an implementation with threads and one without, which needs a host that has them. (`03-standard-library.choosing-an-io`)*

## `Io.Threaded` is the default

```zig
var pool: std.Io.Threaded = .init(init.gpa, .{});
defer pool.deinit();
const io = pool.io();
```

A thread pool, portable to every target Zig supports, and what `init.io` hands
you unless the target has no threads. The allocator is used only to spawn
tasks: pass `Allocator.failing` if you never call `async` or `concurrent` and
the implementation will still work for plain I/O.

Two options are worth knowing. `async_limit` caps the pool used by `io.async`;
past it, tasks run inline rather than waiting for a thread. `concurrent_limit`
caps `io.concurrent`, and past it the call returns
`error.ConcurrencyUnavailable`. The snippet builds a second instance with
`.concurrent_limit = .nothing` to show what code sees on a target that cannot
give it real concurrency, without leaving the host to find one.

## `init_single_threaded` spawns nothing

```zig
var lone: std.Io.Threaded = .init_single_threaded;
```

A compile-time constant instance: no allocator, no threads, no deinit needed.
`async` still works, because `async` is allowed to run the task inline;
`concurrent` always fails and cancellation requests do nothing. This is what a
wasm build gets, and it is why every browser playground on this site runs the
same source as CI does.

It is also the honest way to test that library code degrades properly. If your
code needs `concurrent`, run it against this instance and find out now.

## Evented implementations

`std.Io.Uring` on Linux and `std.Io.Kqueue` on Darwin and the BSDs are the
other two in the standard library. Rather than parking a thread per blocking
call, they submit the operation to the kernel and suspend the task. A task
that suspends this way costs a stack rather than a thread. `std.Io.fiber` is
the machinery that does it, saving a handful of registers and switching
stacks; it is what an implementation uses, not something application code
calls.

That is the payoff the `Io` parameter was for. A server written against the
interface runs on a thread pool during development and on io_uring in
production, without a line changing. The decision stays in `main`, where you
can see it.

## Library code names none of them

```zig
fn run(io: std.Io, ...) !void
```

The function in the snippet is called three times with three different
implementations and does not know the difference. Take an `Io` parameter,
never reach for a global, and handle `error.ConcurrencyUnavailable` where you
ask for concurrency. Then the choice on this page is the caller's, which is
the entire point of making blocking go through an interface.

`Io.Threaded.global_single_threaded` exists as an escape hatch for debugging
and for code that genuinely cannot take a parameter. Reaching for it in a
library gives back the property this whole design bought.
