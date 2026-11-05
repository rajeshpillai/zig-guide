# Cancellation

> How to stop a task that runs, and the cancellation points that make it possible.

Sometimes you must stop a task that you started. For example, the client
closed the connection, the timeout occurred, or the user pressed Ctrl-C.

In Zig, cancellation is a request. It does not kill the task. You send the
request, and the task gets the request at its next *cancellation point*.

```zig
const std = @import("std");

/// Sleeps for an hour, or until a caller cancels it. `io.sleep` is a
/// *cancellation point*: a function on `Io` that can return `error.Canceled`.
fn nap(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

/// The same sleep, but it records how it ended. Then the program can examine
/// the group below after the sleep ends.
fn trackedNap(io: std.Io, status: *[]const u8) std.Io.Cancelable!void {
    io.sleep(.fromSeconds(3600), .awake) catch |err| {
        status.* = @errorName(err);
        return err;
    };
    status.* = "finished";
}

/// Pure computation calls nothing on `Io`. Thus it has no cancellation point,
/// and it spins forever. `io.checkCancel` is the point that you add.
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

    // `cancel` is `await` plus a cancellation request. It blocks until the task
    // is done, and it returns the value that the task returned.
    var sleeping = try io.concurrent(nap, .{io});
    if (sleeping.cancel(io)) |_| {
        try out.print("nap: finished\n", .{});
    } else |err| {
        try out.print("nap: {s}\n", .{@errorName(err)});
    }

    // If you cancel a task that is already complete, the result is not an
    // error. The task has no cancellation point left, thus you get the result.
    var finished = io.async(double, .{21});
    try out.print("double: {d}\n", .{finished.cancel(io)});

    // The task sees the request only because it asks. If you remove the
    // `checkCancel`, this line never prints.
    var counter: u64 = 0;
    var counting = try io.concurrent(count, .{ io, &counter });
    if (counting.cancel(io)) |_| {
        try out.print("count: finished\n", .{});
    } else |err| {
        try out.print("count: {s}\n", .{@errorName(err)});
    }

    // A Group cancels as a whole. Each member gets the request, and `cancel`
    // returns when all of the members stop.
    //
    // Use `concurrent`, not `async`. `async` can run the task on this thread.
    // The threaded `Io` does that when it has no spare capacity: `async_limit`
    // has a default of one less than the core count. A sleep on this thread
    // sleeps for an hour here, and the program never gets to `group.cancel`.
    //
    // The program hangs when the group is equal to or larger than the core
    // count. Thus it passes on a development computer and deadlocks on a
    // small one.
    var status: [3][]const u8 = @splat("still running");
    var group: std.Io.Group = .init;
    for (&status) |*slot| try group.concurrent(io, trackedNap, .{ io, slot });
    group.cancel(io);
    for (status, 0..) |s, i| try out.print("group task {d}: {s}\n", .{ i, s });

    try out.flush();
}
```

*CI builds and runs this program natively. To cancel a task that still runs, the Io must run the task in a different place. wasm32-wasi cannot do that. (`03-standard-library.cancellation`)*

## `cancel` is `await` plus a request

```zig
var sleeping = try io.concurrent(nap, .{io});
if (sleeping.cancel(io)) |_| { ... } else |err| { ... }
```

`Future.cancel` blocks until the task is done, exactly like `await`. Then it
returns the value that the task returned. The difference is that `cancel`
first asks the task to stop. Thus a cancelled task still runs its `defer`
statements and releases its resources. The task always stops before the runtime
removes its stack.

If you cancel a task that is already complete, the result is not an error. The
task has no cancellation point left to reach. Thus `cancel` only returns the
result. `cancel` and `await` are both idempotent, and neither is threadsafe.

## A cancellation point is a call on `Io`

The task gets the request at the next call on its `Io` that can return
`error.Canceled`. Examples are a sleep, a read, a lock and an accept. That is
the rule, and the rule has a result:

```zig
fn count(io: std.Io, counter: *u64) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        counter.* += 1;
    }
}
```

Pure computation calls nothing on `Io`. Thus it has no cancellation point, and
you cannot cancel it. If you delete the `checkCancel` above, the loop runs
forever, and the task never gets the request.

`io.checkCancel` adds a cancellation point to code that has no other one. A
long computation loop needs one. The number of calls depends on how quickly
the loop must stop.

## Do not ignore `error.Canceled`

Only the *next* cancellation point reports the request. After that, the
request ends, and later points return normally. Thus, if a task catches
`error.Canceled` and continues, nothing tells the task again.

To ignore `error.Canceled` is a bug in almost all cases. Return the error to
the caller. Then the caller that asked for the cancellation can see that the
cancellation occurred.

Two functions change how the task gets requests:

- `io.recancel` makes a request that you handled active again. Then the next
  point reports it again.
- `io.swapCancelProtection(.blocked)` stops all delivery across a region that
  must not stop halfway, for example a rollback or a flush. The function
  returns the previous state. Restore that state in a `defer`.

Both functions are for the cleanup path. Do not use them to keep a cancelled
task in operation.

## A `Group` cancels as a whole

```zig
var group: std.Io.Group = .init;
for (&status) |*slot| try group.concurrent(io, trackedNap, .{ io, slot });
group.cancel(io);
```

Each member gets the request. `cancel` returns when all of the members
stop.

This is the main advantage of [structured
concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/), and it is the reason to
pass the extra parameter. For example, a server has one `Group` of connection
handlers. To stop, the server cancels the group. The server has no list of
threads to track. Also, no handler continues to run after the end of the
scope that started it.

A `Group` is also a cancellation boundary. Its tasks must return a value that
can coerce to `Cancelable!void`. If a member returns `error.Canceled`, the
error stops at the group and does not go out of the group.

`Group.await` returns `error.Canceled` when the task that awaits is itself
cancelled. It does not return the error because of a cancelled member. If you
must know how a member ended, record the result. The snippet does this: each
task writes its result into a slot.

## Use `concurrent` for a task that you intend to cancel

The loop above uses `group.concurrent`, not `group.async`. The difference
changes what the program does.

`async` can run the task on the thread that calls it. The threaded `Io` does
exactly that when it has no spare capacity. Its `async_limit` has a default of
one less than the number of logical cores. Past that limit, `async` runs the
task immediately. It does not schedule the task.

For a task that ends without help, that is correct. For this reason,
[`concurrency`](https://www.ziglang.in/learn/concurrency/async-future-group/) starts eight
`accumulate` tasks with `group.async`. Each task adds a number and returns.
Thus, if a task runs inline, the only loss is parallelism.

For a task that ends only when cancelled, the result is a deadlock.
`trackedNap` sleeps for an hour. If it runs inline, it sleeps for an hour on
the thread that must call `group.cancel` next. Thus the program never gets to
that call.

This problem is not a race. The deadlock occurs each time that the group is
equal to or larger than the core count. It never occurs below the core count.
With three sleepers, the program hangs on a computer with one, two or three
cores. It passes on four cores.

This type of bug is very difficult to find. The program passes on the
computer where you wrote it, and it hangs on the smaller computer where you
deploy it. This snippet had the bug. A CI runner with four cores and a
different program in operation found the bug.

`concurrent` makes a promise that `async` does not make. The task runs in a
different place, or the call fails with `error.ConcurrencyUnavailable`. For
the same reason, the program starts `nap` and `count` above with `io.concurrent`.

## Cancellation is why `lock` can fail

`Io.Mutex.lock`, `io.sleep` and
[`Io.RwLock.lock`](https://www.ziglang.in/learn/concurrency/locks/) all return `Cancelable!void`.
Older code had a plain `void` in those places. `Cancelable` is an error set
with one member, and that member is `error.Canceled`.

Thus, if the only error in a signature is `error.Canceled`, the signature
tells you one thing: the call is a cancellation point. When a call must not be
a cancellation point, the standard library puts that fact in the name:
`lockUncancelable`, `futexWaitUncancelable`.
