# Locks and Semaphores

> RwLock, Semaphore and Condition, for the cases where a Mutex is not sufficient.

`Io.Mutex` is sufficient for most shared state. When it is not sufficient,
use `RwLock`, `Semaphore` or `Condition`. Each one takes the `Io` instance,
for the same reason as the mutex. A blocking call goes through the interface.
Thus you can cancel it, and it works on an implementation with no threads.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An RwLock admits any number of readers at the same time, or exactly one writer.
    var rw: std.Io.RwLock = .init;

    try rw.lockShared(io);
    try rw.lockShared(io);
    try out.print("two readers: yes\n", .{});

    // `tryLock` never blocks. It tells you if it got the lock. Readers hold the
    // lock, thus a writer cannot get it.
    try out.print("writer while reading: {}\n", .{rw.tryLock(io)});

    rw.unlockShared(io);
    rw.unlockShared(io);

    // When the readers release the lock, the writer gets it.
    try out.print("writer once alone: {}\n", .{rw.tryLock(io)});
    rw.unlock(io);

    // A semaphore counts permits. It does not give exclusive access. With two
    // permits, two tasks continue, and the third task must wait.
    var sem: std.Io.Semaphore = .{ .permits = 2 };
    try sem.wait(io);
    try sem.wait(io);
    try out.print("permits taken: 2, left: {d}\n", .{sem.permits});

    // Use `waitTimeout` when a permit may never come. Then the task does not
    // wait forever. Here, no code releases a permit.
    const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };
    if (sem.waitTimeout(io, patience)) |_| {
        try out.print("third permit: taken\n", .{});
    } else |err| {
        try out.print("third permit: {s}\n", .{@errorName(err)});
    }

    sem.post(io);
    try out.print("after post, left: {d}\n", .{sem.permits});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.locks`)*

## `RwLock`: many readers or one writer

```zig
try rw.lockShared(io);
try rw.lockShared(io);
```

Two readers hold the lock at the same time. A writer cannot get the lock with
them, and a reader cannot get the lock with a writer.

Use an `RwLock` only when these two conditions are true:

- Reads are much more frequent than writes.
- The reads hold the lock for a long time, and that time has an effect.

An `RwLock` does more bookkeeping than a `Mutex`. Thus, for a short critical
section, the plain mutex is usually faster.

`tryLock` and `tryLockShared` never block. They tell you if they got the
lock. The snippet uses them to show two results: while readers hold the lock,
the writer cannot get it. When the readers release the lock, the writer gets
it.

Unlock with the call that agrees with the lock:

- `unlockShared` for a shared lock.
- `unlock` for an exclusive lock.

## `Semaphore`: a count, not exclusion

```zig
var sem: std.Io.Semaphore = .{ .permits = 2 };
try sem.wait(io);
sem.post(io);
```

A semaphore counts permits. `wait` takes one permit, and it blocks while no
permit is available. `post` adds one permit.

A semaphore has no connection to the task that waited. This property makes a
semaphore different from a mutex. Use a semaphore to set a limit on the
number of tasks in one place at the same time. For example, you can set a
maximum number of active requests to a service that cannot accept more.

`waitTimeout` stops after a time. It does not wait forever:

```zig
const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };
if (sem.waitTimeout(io, patience)) |_| { ... } else |err| { ... }
```

When the time ends, `waitTimeout` returns `error.Timeout`. When a request
cancels the task, it returns `error.Canceled`. Thus you can always tell the
two cases apart.

`Io.Timeout` is a union of `.none`, a duration, or an absolute deadline. A
duration includes the clock that measures it. Here, the clock is `.awake`.

## `Condition`: wait for a predicate

`Io.Condition` is the third tool, and `Semaphore` uses it internally. To use
a condition, do these steps:

1. Hold a mutex.
2. Test the value that you need.
3. Wait for a signal. While you wait, the condition releases the mutex.

```zig
while (!ready) try cond.wait(io, &mutex);
```

The loop is necessary. A wakeup does not promise that the predicate is true.
It tells you only that a new check can be useful.

## Static initialisation, no deinit

`.init` on `Mutex` and `RwLock`, and a plain struct literal on `Semaphore`,
are compile-time constants. None of these types own memory or a handle. Thus
you have no deinit to call, and the construction cannot fail.

You can put a lock in a global or in a struct field. You can also put it on
the stack of the function that spawns the tasks that share the lock.
