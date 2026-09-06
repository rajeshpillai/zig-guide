# The Io Interface

> Anything that can block takes an Io; the caller picks how.

Modern Zig has one idea running through its whole standard library: any
operation that can block, reading a file, opening a socket, sleeping, reading
the clock, takes an `std.Io` parameter. Nothing blocks behind your back, the
same way nothing allocates behind your back. If a function's signature has no
`Io`, it cannot do I/O.

```zig
const std = @import("std");
const expect = std.testing.expect;

// A function that takes an `Io` is announcing, in its signature, that it may
// block: read a clock, touch a file, wait on the network. It does not decide
// *how* that blocking is serviced; the `Io` it is handed does.
fn elapsedNanos(io: std.Io) i96 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var acc: u64 = 0;
    for (0..10_000) |i| acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return start.durationTo(end).raw.toNanoseconds();
}

test "get an Io and pass it down" {
    // In a test the instance is `std.testing.io`. In a program it is
    // `init.io`, the field on the `std.process.Init` your `main` receives.
    // Both are backed by `std.Io.Threaded`: a real thread pool.
    const io = std.testing.io;
    try expect(elapsedNanos(io) >= 0);
}

fn double(out: *u32, value: u32) void {
    out.* = value * 2;
}

test "the same Io is what makes concurrency work" {
    // Because blocking goes through the interface, the interface can also
    // *schedule* it. `io.async` starts a task; the Threaded io runs it on
    // another thread. Swap in an event-loop io and the identical call would
    // suspend a coroutine instead. The calling code does not change.
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

`std.Io` is an interface: a pointer plus a vtable, exactly the shape of
`std.mem.Allocator`. The vtable holds function pointers for the primitive
operations, reading, writing, waiting, scheduling, and a concrete
implementation fills them in. The standard one is `std.Io.Threaded`, backed by
a real thread pool; [Choosing an Io](https://www.ziglang.in/learn/standard-library/choosing-an-io/)
covers the others and when you would swap. It is the same dependency-injection
pattern the allocator uses, applied to blocking instead of to memory. That is
why this chapter sits next to
[Allocators](https://www.ziglang.in/learn/standard-library/allocators/): learn the two together and
the rest of the library stops surprising you.

## Where an `Io` comes from

You almost never construct one. It arrives at the top of your program and you
thread it downward:

| Context | The `Io` you use |
| --- | --- |
| `main` | `init.io`, a field on the `std.process.Init` passed to `main` |
| A test | `std.testing.io` |
| A library function | whatever the caller hands you: take `io: std.Io` |

A function that needs to block does not reach for a global. It accepts an `Io`
and passes it to the calls that block. This is why `std.Io.File.readFile`,
`std.Io.Clock.Timestamp.now`, and `Io.Mutex.lock` all take one as their first
argument.

## Why route everything through one interface

Two payoffs justify the parameter that is now on every I/O call.

**The signature tells the truth.** A function that takes an `Io` announces that
it may block; one that does not, cannot. You can see a function's effects from
its type, with no documentation and no surprises, the same guarantee the
allocator parameter gives you for memory.

**The caller chooses the execution model.** Because blocking goes *through* the
interface, the interface can also schedule it. `io.async` starts a task: on
`Io.Threaded` it runs on another thread; hand the same code an event-loop `Io`
and the identical call suspends a coroutine instead. The function being called
never changes. This is Zig's answer to the "function coloring" problem, there
is no separate `async` version of `readFile`, only one function that does
whatever the `Io` it was given does.

The [Concurrency](https://www.ziglang.in/learn/standard-library/concurrency/) chapter builds on this
with `async` and `Group`, and
[Cancellation](https://www.ziglang.in/learn/standard-library/cancellation/) with stopping a task
once it is running. [Readers and
Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/),
[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) and
[Time](https://www.ziglang.in/learn/standard-library/time/) are each one corner of the same
interface.

## If you are arriving from an older Zig

This is the change nicknamed *"writergate"* (Zig 0.15) and its follow-on work.
Code that once wrote `std.fs.cwd().openFile(...)` or `std.time.timestamp()`
with no `Io` in sight now routes through `std.Io.Dir` and `std.Io.Clock`. The
free-standing, globally-available I/O functions are gone; the [migration
page](https://www.ziglang.in/learn/getting-started/coming-from-older-zig/) lists the specific
renames.
