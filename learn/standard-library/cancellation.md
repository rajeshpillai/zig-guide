# Cancellation

> Stopping a running task, and the cancellation points that make it possible.

A task you started is a task you may need to stop: the client hung up, the
timeout fired, the user pressed Ctrl-C. Cancellation in Zig is a request, not
a kill. You ask, and the task finds out at its next *cancellation point*.

```zig
const std = @import("std");

/// Sleeps for an hour, or until someone cancels it. `io.sleep` is a
/// *cancellation point*: a function on `Io` that can return `error.Canceled`.
fn nap(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

/// Same nap, but recording how it ended so the group below can be inspected
/// after the fact.
fn trackedNap(io: std.Io, status: *[]const u8) std.Io.Cancelable!void {
    io.sleep(.fromSeconds(3600), .awake) catch |err| {
        status.* = @errorName(err);
        return err;
    };
    status.* = "finished";
}

/// Pure computation calls nothing on `Io`, so it has no cancellation point of
/// its own and would spin forever. `io.checkCancel` is the point you add.
fn count(io: std.Io, counter: *u64) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        counter.* += 1;
    }
}

fn double(value: u32) u32 {
    return value * 2;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `cancel` is `await` plus a cancellation request: it blocks until the task
    // is done, and hands back what the task returned.
    var sleeping = try io.concurrent(nap, .{io});
    if (sleeping.cancel(io)) |_| {
        try out.print("nap: finished\n", .{});
    } else |err| {
        try out.print("nap: {s}\n", .{@errorName(err)});
    }

    // Cancelling a task that already finished is not an error. There was no
    // cancellation point left to reach, so you get the result.
    var finished = io.async(double, .{21});
    try out.print("double: {d}\n", .{finished.cancel(io)});

    // The counting task only notices because it asks. Take the `checkCancel`
    // out and this line never prints.
    var counter: u64 = 0;
    var counting = try io.concurrent(count, .{ io, &counter });
    if (counting.cancel(io)) |_| {
        try out.print("count: finished\n", .{});
    } else |err| {
        try out.print("count: {s}\n", .{@errorName(err)});
    }

    // A Group cancels as a whole: every member gets the request, and `cancel`
    // returns once all of them have stopped.
    //
    // `concurrent`, not `async`. `async` may run the task on this thread, and
    // the threaded `Io` does once it is out of spare capacity: `async_limit`
    // defaults to one less than the core count. A nap run on this thread naps
    // for an hour here, and `group.cancel` below is never reached. It hangs
    // whenever the group is at least as large as the core count, so it passes
    // on a development machine and deadlocks on a small one.
    var status: [3][]const u8 = @splat("still running");
    var group: std.Io.Group = .init;
    for (&status) |*slot| try group.concurrent(io, trackedNap, .{ io, slot });
    group.cancel(io);
    for (status, 0..) |s, i| try out.print("group task {d}: {s}\n", .{ i, s });

    try out.flush();
}
```

*Built and run natively by CI. Cancelling a task that is still running needs an Io that can run it somewhere else, and wasm32-wasi cannot. (`03-standard-library.cancellation`)*

## `cancel` is `await` plus a request

```zig
var sleeping = try io.concurrent(nap, .{io});
if (sleeping.cancel(io)) |_| { ... } else |err| { ... }
```

`Future.cancel` blocks until the task is done, exactly like `await`, and hands
back what the task returned. The difference is that it first asks the task to
stop. So a cancelled task still gets to run its `defer`s and release what it
holds; there is no point at which its stack is yanked out from under it.

Cancelling a task that already finished is not an error. There was no
cancellation point left to reach, so `cancel` just returns the result. Both
`cancel` and `await` are idempotent, and neither is threadsafe.

## A cancellation point is a call on `Io`

The request is delivered at the next function the task calls on its `Io` that
can return `error.Canceled`: a sleep, a read, a lock, an accept. That is the
whole rule, and it has a consequence:

```zig
fn count(io: std.Io, counter: *u64) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        counter.* += 1;
    }
}
```

Pure computation calls nothing on `Io`, so it has no cancellation point and
cannot be cancelled. Delete the `checkCancel` above and the loop spins forever
with the request sitting undelivered. `io.checkCancel` exists to put a point
into code that would otherwise have none. Long compute loops need one; how
often depends on how quickly you need it to stop.

## `error.Canceled` is not a failure to swallow

Only the *next* cancellation point reports it. After that the request is
spent, and later points return normally, so a task that catches
`error.Canceled` and carries on will not be told again. That makes ignoring it
a bug in almost every case: propagate it, and let the caller who asked for the
cancellation see that it happened.

`renew` re-arms a request you have handled, so the next point sees it again.
`protect` (via `Cancelable`) blocks delivery across a region that must not be
interrupted, such as a rollback or a flush. Both are for the cleanup path, not
for staying alive.

## A `Group` cancels as a whole

```zig
var group: std.Io.Group = .init;
for (&status) |*slot| try group.concurrent(io, trackedNap, .{ io, slot });
group.cancel(io);
```

Every member gets the request, and `cancel` returns once all of them have
stopped. This is what makes [structured
concurrency](https://www.ziglang.in/learn/standard-library/concurrency/) worth the extra parameter.
A server holding one `Group` of connection handlers shuts down by cancelling
the group. There is no list of threads to track, and no handler left running
after the scope that started it is gone.

A `Group` is also a cancellation boundary. Its tasks must return something
coercible to `Cancelable!void`, and a member returning `error.Canceled` stops
at the group rather than propagating out of it. `Group.await` returns
`error.Canceled` when the task doing the awaiting is itself cancelled, not
because a member was. If you want to know how a member ended, record it, the
way the snippet writes each task's outcome into a slot.

## Use `concurrent` for a task you intend to cancel

That loop says `group.concurrent`, not `group.async`, and the difference is not
style. `async` is allowed to run the task on the calling thread. The threaded
`Io` does exactly that once it runs out of spare capacity. Its `async_limit`
defaults to one less than the number of logical cores, and past that limit
`async` runs the task immediately instead of scheduling it.

For a task that finishes on its own that is fine. It is why
[`concurrency`](https://www.ziglang.in/learn/standard-library/concurrency/) starts eight `accumulate`
tasks with `group.async`: each one adds a number and returns, so running inline
costs nothing but parallelism.

For a task that only ends when cancelled it is a deadlock. `trackedNap` sleeps
for an hour. Run inline, it sleeps for an hour on the thread that was about to
call `group.cancel`, and that call is never reached.

This is not a race. It happens every time the group is at least as large as the
core count, and never below it. Three sleepers hang on a machine with one, two
or three cores and pass on four. That is the worst shape a bug can have: it
passes on the machine you wrote it on, and hangs on the smaller one you deploy
to. This snippet had it, and it took a CI runner with four cores and something
else running to find it.

`concurrent` makes the promise `async` withholds. The task runs somewhere else,
or the call fails with `error.ConcurrencyUnavailable` and you are told. That is
also why `nap` and `count` further up are started with `io.concurrent`.

## Cancellation is why `lock` can fail

`Io.Mutex.lock`, `io.sleep` and
[`Io.RwLock.lock`](https://www.ziglang.in/learn/standard-library/locks/) all return
`Cancelable!void` where older code had a plain `void`. `Cancelable` is a
one-member error set, and that member is `error.Canceled`. So a signature
whose only error is that one is telling you it is a cancellation point and
nothing more. Where a call genuinely must not be one, the standard library
spells it out: `lockUncancelable`, `futexWaitUncancelable`.
