# Atomics

> One counter, every way to add one to it, and what that ordering argument is for.

Adding one to a number is three steps.

Read it. Add one. Write it back.

On a single thread nobody can tell.

With two threads it is a gap, and an update can fall into it.

This chapter is about the operations that close the gap, and about the argument every one of them takes that most tutorials skip.

The program runs in your browser.

It starts no threads and needs none, because what an atomic operation *is* does not depend on having something to race against.

```zig
const std = @import("std");

const Atomic = std.atomic.Value;

/// Two workers increment one plain counter, with the read-modify-write spelled
/// out in the order a race would have run it. Nothing here races: this is what
/// a race produces.
fn lostUpdate() u32 {
    var plain: u32 = 0;
    const a_read = plain; // worker A reads 0
    const b_read = plain; // worker B reads 0
    plain = b_read + 1; // worker B writes 1
    plain = a_read + 1; // worker A writes 1, over the top of B
    return plain;
}

/// The same two increments, with nothing able to get between the read and the
/// write.
fn atomicIncrements() u32 {
    var counter: Atomic(u32) = .init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    return counter.load(.monotonic);
}

/// Multiplying takes a loop, because there is no `fetchMul`: read the value,
/// compute the new one, and swap only if nobody changed it underneath us.
fn multiplyBy(counter: *Atomic(u32), factor: u32) void {
    var seen = counter.load(.monotonic);
    while (counter.cmpxchgWeak(seen, seen * factor, .monotonic, .monotonic)) |actual| {
        seen = actual;
    }
}

/// The `.release` store promises that the write to `payload` is visible to
/// anything that reads `true` back through an `.acquire` load.
fn publish(payload: *u32, ready: *Atomic(bool), value: u32) void {
    payload.* = value;
    ready.store(true, .release);
}

/// The other half of the pair. Null means the writer has not published yet.
fn consume(payload: *const u32, ready: *const Atomic(bool)) ?u32 {
    if (!ready.load(.acquire)) return null;
    return payload.*;
}

/// A lock is not a primitive. One compare-and-swap takes it, one ordered store
/// drops it, and that is the whole type. `std.atomic.Mutex` is this.
const SpinLock = enum(u8) {
    unlocked,
    locked,

    fn tryLock(self: *SpinLock) bool {
        return @cmpxchgStrong(SpinLock, self, .unlocked, .locked, .acquire, .monotonic) == null;
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(SpinLock, self, .unlocked, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("two increments, plain:  {d}\n", .{lostUpdate()});
    try out.print("two increments, atomic: {d}\n", .{atomicIncrements()});

    // Every fetch operation returns the value from before the change, which is
    // what makes it a ticket dispenser: no two callers get the same number.
    var counter: Atomic(u32) = .init(2);
    const before = counter.fetchAdd(10, .monotonic);
    try out.print("fetchAdd returned {d}, counter is now {d}\n", .{ before, counter.load(.monotonic) });

    multiplyBy(&counter, 3);
    try out.print("after the CAS loop: {d}\n", .{counter.load(.monotonic)});

    // A compare-and-swap returns null when it succeeded, and the value that
    // was really there when it did not.
    const wrong_guess = counter.cmpxchgStrong(0, 99, .monotonic, .monotonic);
    try out.print("cmpxchg against a wrong guess: {?d}\n", .{wrong_guess});

    var payload: u32 = 0;
    var ready: Atomic(bool) = .init(false);
    try out.print("before publish: {?d}\n", .{consume(&payload, &ready)});
    publish(&payload, &ready, 7);
    try out.print("after publish:  {?d}\n", .{consume(&payload, &ready)});

    var lock: SpinLock = .unlocked;
    try out.print("first tryLock:  {}\n", .{lock.tryLock()});
    try out.print("second tryLock: {}\n", .{lock.tryLock()});
    lock.unlock();
    try out.print("after unlock:   {}\n", .{lock.tryLock()});
    lock.unlock();

    // Ordering is an argument to each operation, weakest first. There is no
    // separate fence builtin to reach for.
    try out.print("orderings:", .{});
    for (std.meta.tags(std.lang.AtomicOrder)) |order| {
        try out.print(" .{t}", .{order});
    }
    try out.print("\n", .{});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.atomics`)*

## A lost update in slow motion

A real race is hard to show, because it only sometimes happens.

So we write the interleaving out by hand instead.

Two workers each want to add one.

Both read before either writes.

<SnippetSource name="03-standard-library.atomics" decl="lostUpdate" />

Worker B does its whole job correctly.

It reads zero, adds one, stores one.

Then worker A stores one on top, because one is what it computed from the zero it read.

```
two increments, plain:  1
```

Two increments went in and one came out.

Nothing above is undefined behaviour and nothing is racing.

It is the same sequence a race would have produced, run in an order we chose so the result is the same every time.

## `fetchAdd` welds the three steps together

`std.atomic.Value(T)` wraps one value and gives it operations that cannot be split.

<SnippetSource name="03-standard-library.atomics" decl="atomicIncrements" />

`fetchAdd` still reads, adds and writes.

The difference is that no other core can observe or modify the value between those parts.

```
two increments, atomic: 2
```

The wrapper is not doing anything clever.

On x86 that line is one `lock xadd` instruction, and the guarantee comes from the hardware.

## Every fetch hands back the old value

`fetchAdd` returns what the counter held *before* the addition.

```
fetchAdd returned 2, counter is now 12
```

The choice is deliberate, and it is the useful one.

It makes the counter a ticket dispenser: two threads calling `fetchAdd(1, ...)` are guaranteed different numbers, and each one knows which number it got.

If it returned the new value you could not tell "I am the third caller" from "I am the fourth", because two callers could see the same total.

The whole family works this way: `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`, `fetchMin`, `fetchMax`.

`swap` is the same idea with no arithmetic.

It stores your value and hands back what was there.

## Compare-and-swap is the general tool

There is no `fetchMul`.

There is no `fetchWhateverYourProblemNeeds` either, and there never will be.

What exists instead is compare-and-swap.

Every other operation on this page is built out of it.

You say what you think the value is, and what you want it to become.

The swap happens only if you were right.

<SnippetSource name="03-standard-library.atomics" decl="multiplyBy" />

Read the loop condition carefully, because the shape is backwards from what it looks like.

`cmpxchgWeak` returns an optional.

**Null means the swap succeeded.** A payload means it failed, and the payload is the value that was really there.

So `while (...) |actual|` loops while the swap is *failing*, and each turn feeds the fresh value back in for another attempt.

We can watch a failure directly by guessing wrong on purpose:

```
cmpxchg against a wrong guess: 36
```

The counter was 36, we guessed 0, and the swap did not happen.

The 36 we got back is the counter telling us what it actually holds.

`cmpxchgWeak` is allowed to fail spuriously even when your guess was right, which sounds unhelpful and is not.

On ARM and RISC-V it compiles to a load-linked/store-conditional pair that a context switch can interrupt, so permitting the odd false failure produces a tighter loop.

Inside a retry loop a spurious failure costs one more turn.

Use `cmpxchgStrong` when there is no loop and a false failure would be wrong.

## Ordering is an argument, not a fence

Every operation so far took a second argument we have not discussed.

There are six values and the program prints them weakest first:

```
orderings: .unordered .monotonic .acquire .release .acq_rel .seq_cst
```

The ordering does not change what happens to the atomic variable.

It constrains what the compiler and the CPU may do with **the other memory around it**.

Both are allowed to reorder your instructions.

Usually that is invisible and free.

Once another thread is watching, the order it sees becomes part of your program's meaning.

`.monotonic` is the weakest ordering a read-modify-write accepts.

It promises the operation itself is indivisible and promises nothing about neighbouring memory.

That is exactly right for a statistics counter, where you want the total at the end and nothing else depends on when each increment landed.

Reach past it when the atomic is a **signal about other data**.

`.seq_cst` is the strongest, and it is the one to use when you are unsure.

It is slower and it is never wrong.

There is no `@fence` builtin to pair with these.

Ordering rides on the operations themselves.

The compiler rejects the combinations that make no sense, so this is not something you have to hold in your head:

```
c.fetchAdd(1, .unordered)   error: @atomicRmw atomic ordering must not be unordered
c.load(.release)            error: @atomicLoad atomic ordering must not be release or acq_rel
c.store(1, .acquire)        error: @atomicStore atomic ordering must not be acquire or acq_rel
```

A load cannot release, because there is nothing to publish.

A store cannot acquire, because there is nothing to read.

Compare-and-swap takes two orderings, one for the success path and one for failure, and the failure one may not be stricter than the success one:

```
c.cmpxchgStrong(0, 1, .monotonic, .acquire)
error: failure atomic ordering must be no stricter than success
```

## Acquire and release are a pair

The pattern worth learning by name is publishing.

One thread fills in some data and then sets a flag.

Another sees the flag and reads the data.

<SnippetSource name="03-standard-library.atomics" decl="publish" />

The `.release` store draws a line.

Every write above it is visible to any thread that reads that `true` back with `.acquire`.

<SnippetSource name="03-standard-library.atomics" decl="consume" />

```
before publish: null
after publish:  7
```

Without the pairing, a reader could see `ready` as true and `payload` as zero.

The two writes are to different addresses, and nothing otherwise stops the store to `payload` from becoming visible second.

The bug that produces is the worst kind.

The window is a few nanoseconds wide, it depends on the CPU, and it does not reproduce under a debugger.

On this page both calls run on one thread, so the output only shows the shape.

The guarantee is real on the targets that need it, and the shape is what you want in your fingers.

`.acq_rel` is for an operation that does both at once, which means a read-modify-write and not a plain load or store.

## A lock is a compare-and-swap

Atomics can look like an exotic layer under the ordinary tools.

They are the layer the ordinary tools are made of.

<SnippetSource name="03-standard-library.atomics" decl="SpinLock" />

Those ten lines are a working mutex.

`tryLock` swaps `unlocked` for `locked` and reports whether it won.

Only one caller can see `unlocked` and take it, because only one compare-and-swap can succeed against a given value.

`unlock` stores `unlocked` back with `.release`, which publishes everything the holder did inside the critical section to whoever takes the lock next.

The orderings are the pattern from the previous section, applied to the lock itself.

```
first tryLock:  true
second tryLock: false
after unlock:   true
```

`std.atomic.Mutex` is this type, in the standard library, at about this length.

What it does not do is wait.

A caller that loses either spins or gives up.

A real mutex has to park the thread and have something wake it, and that part belongs to the operating system.

[`Io.Mutex`](https://www.ziglang.in/learn/concurrency/locks/) takes an `Io` for exactly that reason.

This does not.

## When a mutex is the better answer

Atomics are for one machine word.

Two related fields cannot be updated atomically together.

If your invariant spans a counter and a pointer, no combination of atomic operations protects it, and reaching for a lock is the answer rather than a compromise.

Lock-free is also not the same as fast.

A contended `fetchAdd` bounces a cache line between cores on every call, and eight threads hammering one counter can be slower than eight threads taking a mutex.

`std.atomic.cache_line` exists so you can pad separate counters onto separate lines when profiling says they are fighting.

The honest rule is narrow.

Use an atomic for a counter, a flag, or a single pointer swapped as a unit.

Use [`Io.Mutex`](https://www.ziglang.in/learn/concurrency/locks/) for anything with an invariant, and reach for [`Io.Queue`](https://www.ziglang.in/learn/concurrency/queues/) before writing a lock-free structure of your own.

## What moved

Two things here differ from what an older tutorial will show you.

`AtomicOrder` now lives in `std.lang`, the home for declarations the standard library shares with the compiler.

`std.builtin` is kept as an alias, so `std.builtin.AtomicOrder` still resolves and the snippet on this page uses `std.lang.AtomicOrder`.

`@fence` is gone.

Code that called it was almost always writing an ordering it could have put on the operation, and that is now the only way to say it.

The builtins are still there under the wrapper.

`@atomicLoad`, `@atomicStore`, `@atomicRmw` and `@cmpxchgStrong` are what `std.atomic.Value` calls, and `SpinLock` above uses two of them directly because an `enum(u8)` is not what `Value` is shaped for.

Next: [Threads](https://www.ziglang.in/learn/concurrency/threads/) for the real threads these guarantees are about, and [Locks and Semaphores](https://www.ziglang.in/learn/concurrency/locks/) for the tools to prefer over these.
