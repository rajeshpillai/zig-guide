# Locks and Semaphores

> RwLock, Semaphore and Condition, past the point where a Mutex is enough.

`Io.Mutex` covers most shared state. All of them take the `Io` instance for
the same reason the mutex does. Blocking goes through the interface, so it can
be cancelled, and it works on an implementation with no threads.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An RwLock admits any number of readers at once, or exactly one writer.
    var rw: std.Io.RwLock = .init;

    try rw.lockShared(io);
    try rw.lockShared(io);
    try out.print("two readers: yes\n", .{});

    // `tryLock` never blocks; it reports whether it got the lock. Readers hold
    // it, so a writer cannot have it.
    try out.print("writer while reading: {}\n", .{rw.tryLock(io)});

    rw.unlockShared(io);
    rw.unlockShared(io);

    // With the readers gone the writer gets in.
    try out.print("writer once alone: {}\n", .{rw.tryLock(io)});
    rw.unlock(io);

    // A semaphore counts permits rather than granting exclusive access. Two
    // permits let two tasks past before the third has to wait.
    var sem: std.Io.Semaphore = .{ .permits = 2 };
    try sem.wait(io);
    try sem.wait(io);
    try out.print("permits taken: 2, left: {d}\n", .{sem.permits});

    // `waitTimeout` is how you avoid waiting forever for a permit that is not
    // coming. There is nothing to release this one.
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

Two readers hold the lock at once. A writer cannot join them, and a reader
cannot join a writer. That is the whole contract. It is worth using only when
reads dominate writes and hold the lock long enough to matter. An `RwLock`
does more bookkeeping than a `Mutex`, so for a short critical section the
plain mutex usually wins.

`tryLock` and `tryLockShared` never block. They return whether they got the
lock, which is how the snippet shows a writer being refused while readers hold
it and admitted once they leave. Unlock with the matching call: `unlockShared`
for a shared acquisition, `unlock` for an exclusive one.

## `Semaphore`: a count, not exclusion

```zig
var sem: std.Io.Semaphore = .{ .permits = 2 };
try sem.wait(io);
sem.post(io);
```

A semaphore counts permits. `wait` consumes one, blocking while there are
none; `post` adds one. Nothing ties a semaphore to the task that waited, which
is what separates it from a mutex. It is for limiting how many tasks may be
somewhere at once, such as capping in-flight requests to a service that will
not tolerate more.

`waitTimeout` gives up rather than waiting forever:

```zig
const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };
if (sem.waitTimeout(io, patience)) |_| { ... } else |err| { ... }
```

It returns `error.Timeout` on expiry and `error.Canceled` if the task itself
is cancelled, so the two cases stay distinguishable. `Io.Timeout` is a union
of `.none`, a duration, or an absolute deadline, and a duration carries the
clock it is measured on, `.awake` here.

## `Condition`: wait for a predicate

`Io.Condition` is the third, and it is what `Semaphore` is built out of. You
hold a mutex, test the thing you care about, and wait for a signal while the
mutex is released:

```zig
while (!ready) try cond.wait(io, &mutex);
```

The loop is not optional. A wakeup does not promise the predicate is true,
only that it might be worth checking again.

## Static initialisation, no deinit

`.init` on `Mutex` and `RwLock`, and a plain struct literal on `Semaphore`,
are compile-time constants. None of these own memory or a handle, so there is
nothing to deinit and nothing that can fail to construct. A lock can live in a
global, in a struct field, or on the stack of the function that spawns the
tasks sharing it.
