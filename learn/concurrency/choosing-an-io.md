# Choose an Io

> Threaded, the evented implementations, and how to build an Io yourself.

Each other chapter in this section takes `init.io` and gives it to the
functions that it calls. This chapter shows where that value comes from. The
program makes the choice, and `main` is the only place in a codebase that must
make it.

```zig
const std = @import("std");

fn double(value: u32) u32 {
    return value * 2;
}

/// Usual library code. It never names an implementation. Thus it works with
/// the implementation that the caller made.
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

    // A thread pool. The implementation uses the allocator only to spawn
    // tasks. All other parts of the implementation do not allocate.
    var pool: std.Io.Threaded = .init(init.gpa, .{});
    defer pool.deinit();
    try run(pool.io(), "threaded", out);

    // The same implementation without concurrency. `async` still works,
    // because it can run the task inline. `concurrent` cannot work.
    var capped: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .nothing });
    defer capped.deinit();
    try run(capped.io(), "capped", out);

    // A static instance that spawns nothing. A target without threads gets
    // this instance, and it needs no allocator.
    var lone: std.Io.Threaded = .init_single_threaded;
    try run(lone.io(), "single-threaded", out);

    try out.flush();
}
```

*CI builds and runs this program natively. The program shows the difference between an implementation with threads and an implementation without threads. Thus it needs a host that has threads. (`03-standard-library.choosing-an-io`)*

## `Io.Threaded` is the default

```zig
var pool: std.Io.Threaded = .init(init.gpa, .{});
defer pool.deinit();
const io = pool.io();
```

`Io.Threaded` is a thread pool. It is portable to each target that Zig
supports. `init.io` gives you this implementation, except when the target has
no threads.

The implementation uses the allocator only to spawn tasks. If you never call
`async` or `concurrent`, you can pass `Allocator.failing`. The implementation
still works for plain I/O.

Two options are useful:

- `async_limit` sets the maximum size of the pool for `io.async`. Past that
  limit, tasks run inline. They do not wait for a thread.
- `concurrent_limit` sets the maximum for `io.concurrent`. Past that limit,
  the call returns `error.ConcurrencyUnavailable`.

The snippet makes a second instance with `.concurrent_limit = .nothing`. This
instance shows what code sees on a target that cannot give real concurrency.
You do not need a different host to see it.

## `init_single_threaded` spawns nothing

```zig
var lone: std.Io.Threaded = .init_single_threaded;
```

This instance is a compile-time constant. It needs no allocator, no threads
and no deinit. `async` still works, because `async` can run the task inline.
`concurrent` always fails, and cancellation requests do nothing.

A wasm build gets this instance. For this reason, each browser playground on
this site runs the same source as CI.

This instance is also a good way to test that library code still works
correctly with no threads. If your code needs `concurrent`, run it against
this instance and find the problem now.

## Evented implementations

The standard library has two more implementations: `std.Io.Uring` on Linux
and `std.Io.Kqueue` on Darwin and the BSDs. They do not park one thread for
each blocking call. Instead, they submit the operation to the kernel and
suspend the task. A task that suspends in this way costs a stack, not a
thread.

`std.Io.fiber` does the work of the suspension. It saves a small number of
registers and changes to a different stack. An implementation uses
`std.Io.fiber`. Application code does not call it.

This is the advantage of the `Io` parameter. You write a server against the
interface. The server runs on a thread pool during development and on
io_uring in production, without a change to one line. The decision between
the two stays in `main`.

## Library code names none of them

```zig
fn run(io: std.Io, ...) !void
```

The snippet calls this function three times with three different
implementations. The function does not know the difference.

To get this result in your library, do these steps:

1. Take an `Io` parameter.
2. Never use a global instead.
3. Handle `error.ConcurrencyUnavailable` where you ask for concurrency.

Then the caller makes the choice on this page. That is the reason that
blocking calls go through an interface.

`Io.Threaded.global_single_threaded` exists as a fallback for debug work. It
is also for code that really cannot take a parameter. If a library uses it,
the library removes the choice of implementation from the caller.
