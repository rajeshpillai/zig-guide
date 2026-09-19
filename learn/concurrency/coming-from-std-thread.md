# Coming from `std.Thread`

> Seven names that were removed, where each one went, and why lock can now fail.

Some code stops compiling and the message is flat:

```
error: struct 'Thread' has no member named 'Mutex'
```

Nothing is deprecated and nothing is renamed in place.

`std.Thread.Mutex` is not there, and neither are six of its neighbours.

They moved to `std.Io`, and the table below is the compiler saying so rather than a changelog.

```zig
const std = @import("std");

const Move = struct {
    /// The name it had on `std.Thread`.
    was: []const u8,
    /// The name it has on `std.Io`.
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

/// What `std.Thread` kept: the parts that are genuinely about an OS thread
/// rather than about waiting for one.
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

Each line is printed from `@hasDecl`, so nothing here can go stale quietly.

If one of these ever comes back, the output changes and the nightly build fails.

## The split, and the reason for it

Seven declarations left. Five stayed.

Look at which went where and the rule falls out.

`spawn`, `detach`, `getCpuCount`, `getCurrentId` and `yield` are about an operating system thread.

They are still on `std.Thread` because that is what they are for.

Everything that moved has one thing in common.

Every one of them **waits**.

A mutex waits for a holder to finish.

A semaphore waits for a permit.

A wait group waits for a count to reach zero.

A pool waits for work.

Waiting is the thing this Zig makes explicit, because a function that can block has to know how the program wants blocking done.

That knowledge is the `Io`, so anything that can block takes one.

A thread is still just a thread, and it needs no such argument.

## The mutex, and why `lock` can fail

The old shape was a zero-initialised struct with infallible methods: `var mutex: std.Thread.Mutex = .{};` and then `mutex.lock()`.

The new shape takes the `Io` on both calls:

<SnippetSource name="03-standard-library.concurrency" decl="accumulate" />

Three things changed in four lines.

The initialiser is `.init` rather than `.{}`, because `Io.Mutex` has state to set rather than a zero value to accept.

`lock` and `unlock` both take the `io`, for the same reason every blocking call does.

`lock` returns an error.

That is the change worth pausing on.

It can fail for exactly one reason: the task waiting on the lock was cancelled.

There is no lock that can be poisoned here and no error you can provoke by using it wrong.

So `catch return` is a reasonable answer in a worker that has just been told to stop.

More often you want `try`, and a caller that already knows what cancellation means.

[Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) is the chapter on that, and it is the reason nearly every signature in this section has an error union in it.

## The pool is now the `Io` itself

`std.Thread.Pool` was a value you built, handed work to, and waited on.

The replacement inverts that.

You choose an implementation once in `main`, and `std.Io.Threaded` is the one with a thread pool inside it.

Everything below `main` takes the interface and never learns whether there is a pool behind it.

So the rewrite is not "find the new `Pool` type".

It is: delete the pool, pass the `io` you already have, and start tasks with `io.async` or a `Group`.

The same code then runs on an implementation with no threads at all.

That portability is why the other chapters in this section have Run buttons.

[Choosing an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) covers what you are choosing between.

## The rest of the table

`WaitGroup` became [`Io.Group`](https://www.ziglang.in/learn/concurrency/async-future-group/).

You start tasks on the group and await the group, rather than counting them up and down by hand.

`RwLock`, `Semaphore` and `Condition` kept their names and gained an `io` parameter.

[Locks and Semaphores](https://www.ziglang.in/learn/concurrency/locks/) covers all three.

`ResetEvent` is now `Io.Event`, the only entry in the table whose name actually changed.

It is worth opening `Io.Event` in the standard library if you have read [Atomics](https://www.ziglang.in/learn/concurrency/atomics/), because it is a three-state enum, one `@cmpxchgStrong` and an `@atomicLoad` with `.acquire`.

The wait primitive is built out of the pieces that chapter ends on.

## Rewriting existing code

The mechanical part is short.

Delete the pool and the wait group.

Add `io: std.Io` to any function that locks, waits, or sleeps, and pass it down from `main`.

Change `.{}` to `.init` on the primitives.

Put `try` in front of `lock`, and let the error travel to whoever owns the cancellation.

Replace `std.Thread.spawn` with `io.async` unless you specifically need an OS thread, and read the difference between `async` and `concurrent` before you rely on either.

The judgement part is shorter still, and it is one question: which functions in your codebase can block?

Those are the ones that take an `Io` now, and the compiler will find every one of them for you.

Next: [The Io Interface](https://www.ziglang.in/learn/standard-library/io-interface/) if that parameter is new, or [Threads](https://www.ziglang.in/learn/concurrency/threads/) for the five declarations that stayed.
