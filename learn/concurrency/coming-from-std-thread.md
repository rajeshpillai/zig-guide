# Migrate from `std.Thread`

> Seven names that Zig removed, where each one went, and why lock can now fail.

Some code does not compile now, and the compiler gives this message:

```
error: struct 'Thread' has no member named 'Mutex'
```

Zig did not deprecate these names, and it did not rename them in place. `std.Thread.Mutex` does not exist now, and six related declarations also do not exist.

They moved to `std.Io`. The table below comes from the compiler, not from a changelog.

```zig
const std = @import("std");

const Move = struct {
    /// The old name on `std.Thread`.
    was: []const u8,
    /// The new name on `std.Io`.
    now: []const u8,
};

const moves = [_]Move{
    .{ .was = "Mutex", .now = "Mutex" },
    .{ .was = "RwLock", .now = "RwLock" },
    .{ .was = "Semaphore", .now = "Semaphore" },
    .{ .was = "Condition", .now = "Condition" },
    .{ .was = "ResetEvent", .now = "Event" },
    .{ .was = "WaitGroup", .now = "Group" },
    .{ .was = "Pool", .now = "Threaded" },
};

/// The declarations that stayed on `std.Thread`. They are about an OS thread,
/// not about a wait for a thread.
const kept = [_][]const u8{ "spawn", "getCpuCount", "getCurrentId", "yield", "detach" };

fn mark(present: bool) []const u8 {
    return if (present) "present" else "gone";
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    inline for (moves) |m| {
        try out.print("std.Thread.{s: <11} {s: <8}  std.Io.{s: <10} {s}\n", .{
            m.was,
            comptime mark(@hasDecl(std.Thread, m.was)),
            m.now,
            comptime mark(@hasDecl(std.Io, m.now)),
        });
    }

    try out.print("\n", .{});

    inline for (kept) |name| {
        try out.print("std.Thread.{s: <13} {s}\n", .{ name, comptime mark(@hasDecl(std.Thread, name)) });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.std-thread-today`)*

The program prints each line from `@hasDecl`. Thus, if the table becomes incorrect, the build finds the problem. If one of these names returns, the output changes and the nightly build fails.

## The split, and the reason for it

Seven declarations moved. Five stayed. Look at where each one went, and you can see the rule.

`spawn`, `detach`, `getCpuCount`, `getCurrentId` and `yield` are about an operating system thread. They are still on `std.Thread`, because that is their purpose.

All the declarations that moved have one thing in common. Each one of them **waits**:

- A mutex waits until a holder is done.
- A semaphore waits for a permit.
- A wait group waits until a count is zero.
- A pool waits for work.

Current Zig makes waits explicit. A function that can block must know how the program wants to block. The `Io` holds that knowledge. Thus each function that can block takes an `Io`.

A thread is still only a thread, and it does not need such an argument.

## The mutex, and why `lock` can fail

The old shape was a struct with a zero initialiser, and its methods could not fail: `var mutex: std.Thread.Mutex = .{};` and then `mutex.lock()`.

The new shape takes the `Io` on the two calls:

```zig
fn accumulate(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    // `Io.Mutex.lock` takes the io instance, like all other functions that can
    // block. It returns an error for one reason only: a task can cancel it.
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}
```

*Quoted from the source: `accumulate` from `snippets/03-standard-library/concurrency.zig`.*

Three things changed in four lines:

- The initialiser is `.init`, not `.{}`. `Io.Mutex` has state to set, not a zero value to accept.
- `lock` and `unlock` both take the `io`, for the same reason as all blocking calls.
- `lock` returns an error.

`lock` can fail for exactly one reason: the task that waits on the lock got a cancellation request. The lock cannot become poisoned, and a wrong use of the lock does not give an error.

Thus `catch return` is a reasonable answer in a worker that just got the request to stop. More often, you need `try`, and a caller that already knows what to do with a cancellation.

[Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) explains that subject. Cancellation is the reason that almost all signatures in this section have an error union.

## The pool is now the `Io` itself

`std.Thread.Pool` was a value that you built. You gave it work, and then you waited on it.

The replacement works in the opposite direction. You select an implementation one time, in `main`. `std.Io.Threaded` is the implementation that has a thread pool inside it. All the code below `main` takes the interface. That code never knows if a pool is behind the interface.

Thus you do not need to find a new `Pool` type. Do these steps instead:

1. Delete the pool.
2. Pass the `io` that you already have.
3. Start tasks with `io.async` or a `Group`.

Then the same code runs on an implementation that has no threads. Because of that, the other chapters in this section have Run buttons.

[Choose an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) explains the options.

## The rest of the table

`WaitGroup` became [`Io.Group`](https://www.ziglang.in/learn/concurrency/async-future-group/). You start tasks on the group and await the group. You do not count the tasks up and down by hand.

`RwLock`, `Semaphore` and `Condition` kept their names, and each one got an `io` parameter. [Locks and Semaphores](https://www.ziglang.in/learn/concurrency/locks/) explains all three.

`ResetEvent` is now `Io.Event`. It is the only entry in the table with a name that really changed.

If you read [Atomics](https://www.ziglang.in/learn/concurrency/atomics/), open `Io.Event` in the standard library. `Io.Event` is a three-state enum, one `@cmpxchgStrong` and an `@atomicLoad` with `.acquire`. These are the parts at the end of that chapter.

## Rewrite old code

The mechanical part is short:

1. Delete the pool and the wait group.
2. Add `io: std.Io` to each function that locks, waits or sleeps. Pass the `io` down from `main`.
3. Change `.{}` to `.init` on the primitives.
4. Put `try` in front of `lock`. Let the error go to the code that owns the cancellation.
5. Replace `std.Thread.spawn` with `io.async`, unless you really need an OS thread.
6. Before you depend on `async` or `concurrent`, read the difference between them.

Then ask one question: which functions in your codebase can block? Those functions take an `Io` now, and the compiler finds each one of them for you.

Next: read [The Io Interface](https://www.ziglang.in/learn/standard-library/io-interface/) if that parameter is new to you. Read [Threads](https://www.ziglang.in/learn/concurrency/threads/) for the five declarations that stayed.
