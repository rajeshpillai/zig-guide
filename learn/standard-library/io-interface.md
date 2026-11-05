# The Io Interface

> Each operation that can block takes an Io. The caller selects how the Io works.

Modern Zig has one idea in all of its standard library. Each operation that can block takes an `std.Io` parameter. Examples are a file read, a socket open, a sleep, and a clock read.

Nothing blocks secretly, as nothing allocates secretly. If the signature of a function has no `Io`, the function cannot do I/O.

```zig
const std = @import("std");
const expect = std.testing.expect;

// A function that takes an `Io` tells you in its signature that it can block.
// For example, it can read a clock, use a file, or wait on the network. The
// function does not decide *how* the blocking operation runs. The `Io` that
// the function receives decides.
fn elapsedNanos(io: std.Io) i96 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var acc: u64 = 0;
    for (0..10_000) |i| acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return start.durationTo(end).raw.toNanoseconds();
}

test "get an Io and pass it down" {
    // In a test, the instance is `std.testing.io`. In a program, it is
    // `init.io`, the field on the `std.process.Init` that `main` receives.
    // `std.Io.Threaded`, a real thread pool, is behind the two instances.
    const io = std.testing.io;
    try expect(elapsedNanos(io) >= 0);
}

fn double(out: *u32, value: u32) void {
    out.* = value * 2;
}

test "the same Io is what makes concurrency work" {
    // Each blocking operation goes through the interface. Thus the interface
    // can also *schedule* the operation. `io.async` starts a task, and the
    // Threaded io runs the task on a different thread. With an event-loop io,
    // the identical call suspends a coroutine. The caller does not change.
    const io = std.testing.io;

    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(double, .{ &a, 10 });
    var second = io.async(double, .{ &b, 20 });
    first.await(io);
    second.await(io);

    try expect(a == 20 and b == 40);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.io-interface`)*

## What `Io` is

`std.Io` is an interface: a pointer and a vtable. This is exactly the shape of `std.mem.Allocator`. The vtable holds function pointers for the primitive operations: read, write, wait and schedule. A concrete implementation supplies these pointers.

The standard implementation is `std.Io.Threaded`, and a real thread pool is behind it. [Choose an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) tells you about the other implementations, and when to change to one of them.

The allocator uses the same dependency-injection pattern for memory, and `Io` uses it for blocking. For this reason, this chapter is next to [Allocators](https://www.ziglang.in/learn/standard-library/allocators/). When you know the two interfaces, you know the pattern of most of the standard library.

## The source of an `Io`

You almost never make an `Io` yourself. The `Io` arrives at the top of your program, and you pass it down to the functions that need it:

| Context | The `Io` that you use |
| --- | --- |
| `main` | `init.io`, a field on the `std.process.Init` that `main` receives |
| A test | `std.testing.io` |
| A library function | the `Io` that the caller gives you: take `io: std.Io` |

A function that must block does not use a global value. It accepts an `Io`, and it gives the `Io` to the calls that block. For this reason, `std.Io.Dir.readFile`,
`std.Io.Clock.Timestamp.now` and `Io.Mutex.lock` all take an `Io` as their first argument.

## The reason for one interface

Each I/O call now has this parameter. The parameter gives two benefits.

**The signature shows what the function does.** A function that takes an `Io` can block. A function that does not take an `Io` cannot block. The type of a function shows its effects, and you do not have to read its documentation. The allocator parameter gives you the same guarantee for memory.

**The caller selects the execution model.** Each blocking operation goes *through* the interface, thus the interface can also schedule it. `io.async` starts a task. On `Io.Threaded`, the task runs on a different thread. If you give the same code an event-loop `Io`, the identical call suspends a coroutine. The called function never changes.

This is the answer of Zig to the "function coloring" problem. No separate `async` version of `readFile` exists. There is one function, and it does what the given `Io` does.

The [Concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/) chapter adds `async` and `Group` to this idea. [Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) shows how to stop a task that runs. [Readers and
Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/),
[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) and
[Time](https://www.ziglang.in/learn/standard-library/time/) each show one part of the same interface.

## If you used an older version of Zig

This change came in Zig 0.15, and more work on it came later. Older code wrote `std.fs.cwd().openFile(...)` or `std.time.timestamp()` with no `Io`. Now the same code goes through `std.Io.Dir` and `std.Io.Clock`.

The global I/O functions without an `Io` parameter are gone. The [migration
page](https://www.ziglang.in/learn/getting-started/coming-from-older-zig/) gives a list of the specific renames.
