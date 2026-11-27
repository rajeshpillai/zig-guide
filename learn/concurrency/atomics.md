# Atomics

> One counter, all the ways to add one to it, and the purpose of the ordering argument.

To add one to a number, the computer does three steps:

1. Read the number.
2. Add one.
3. Write the number back.

On one thread, the three steps cause no problem. With two threads, a different thread can act between the steps, and the program can lose an update.

This chapter shows the operations that prevent a lost update. It also shows the ordering argument that each of these operations takes.

The program runs in your browser. It starts no threads, and it does not need threads. An atomic operation does the same thing when no other thread runs.

```zig
const std = @import("std");

const Atomic = std.atomic.Value;

/// Two workers increment one plain counter. The code writes each step of the
/// read-modify-write in the order that a race can run the steps. This code has
/// no race. It shows the result that a race makes.
fn lostUpdate() u32 {
    var plain: u32 = 0;
    const a_read = plain; // worker A reads 0
    const b_read = plain; // worker B reads 0
    plain = b_read + 1; // worker B writes 1
    plain = a_read + 1; // worker A writes 1, over the value from B
    return plain;
}

/// The same two increments. No other operation can occur between the read and
/// the write.
fn atomicIncrements() u32 {
    var counter: Atomic(u32) = .init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    return counter.load(.monotonic);
}

/// A multiplication needs a loop, because no `fetchMul` exists. Read the value,
/// calculate the new value, and swap only if no other thread changed it.
fn multiplyBy(counter: *Atomic(u32), factor: u32) void {
    var seen = counter.load(.monotonic);
    while (counter.cmpxchgWeak(seen, seen * factor, .monotonic, .monotonic)) |actual| {
        seen = actual;
    }
}

/// The `.release` store promises that the write to `payload` is visible to
/// each reader that gets `true` from an `.acquire` load.
fn publish(payload: *u32, ready: *Atomic(bool), value: u32) void {
    payload.* = value;
    ready.store(true, .release);
}

/// The other half of the pair. Null means that the writer did not publish yet.
fn consume(payload: *const u32, ready: *const Atomic(bool)) ?u32 {
    if (!ready.load(.acquire)) return null;
    return payload.*;
}

/// A lock is not a primitive. One compare-and-swap takes the lock, and one
/// ordered store releases the lock. The type needs nothing more.
/// `std.atomic.Mutex` is this type.
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

    // Each fetch operation returns the value from before the change. Thus the
    // counter can give tickets: no two callers get the same number.
    var counter: Atomic(u32) = .init(2);
    const before = counter.fetchAdd(10, .monotonic);
    try out.print("fetchAdd returned {d}, counter is now {d}\n", .{ before, counter.load(.monotonic) });

    multiplyBy(&counter, 3);
    try out.print("after the CAS loop: {d}\n", .{counter.load(.monotonic)});

    // A compare-and-swap returns null when it is successful. When it fails, it
    // returns the value that was really there.
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

    // Ordering is an argument to each operation. The loop prints the orderings,
    // weakest first. No separate fence builtin exists.
    try out.print("orderings:", .{});
    for (std.meta.tags(std.lang.AtomicOrder)) |order| {
        try out.print(" .{t}", .{order});
    }
    try out.print("\n", .{});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.atomics`)*

## A lost update, step by step

A real race is difficult to show, because it occurs only sometimes. Thus the program writes the interleaving by hand.

Two workers each must add one. Both workers read before one of them writes.

```zig
/// Two workers increment one plain counter. The code writes each step of the
/// read-modify-write in the order that a race can run the steps. This code has
/// no race. It shows the result that a race makes.
fn lostUpdate() u32 {
    var plain: u32 = 0;
    const a_read = plain; // worker A reads 0
    const b_read = plain; // worker B reads 0
    plain = b_read + 1; // worker B writes 1
    plain = a_read + 1; // worker A writes 1, over the value from B
    return plain;
}
```

*Quoted from the source: `lostUpdate` from `snippets/03-standard-library/atomics.zig`.*

Worker B does all of its work correctly. It reads zero, adds one, and stores one.

Then worker A stores one over the value from worker B. Worker A read zero, thus worker A calculated one.

```
two increments, plain:  1
```

The program did two increments, and the result is one.

The code above has no undefined behaviour, and no race occurs. The code runs the same sequence that a race can make. The program selects the order, thus the result is the same on each run.

## `fetchAdd` makes the three steps one operation

`std.atomic.Value(T)` contains one value. It gives the value operations that a different thread cannot divide.

```zig
/// The same two increments. No other operation can occur between the read and
/// the write.
fn atomicIncrements() u32 {
    var counter: Atomic(u32) = .init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    return counter.load(.monotonic);
}
```

*Quoted from the source: `atomicIncrements` from `snippets/03-standard-library/atomics.zig`.*

`fetchAdd` still reads, adds and writes. But no other core can see or change the value between those three parts.

```
two increments, atomic: 2
```

The wrapper adds no logic. On x86, that line is one `lock xadd` instruction. The hardware gives the guarantee.

## Each fetch returns the old value

`fetchAdd` returns the value that the counter held *before* the addition.

```
fetchAdd returned 2, counter is now 12
```

This design is intentional, and it is useful. With it, the counter can give tickets. If two threads call `fetchAdd(1, ...)`, each thread gets a different number. Each thread also knows which number it got.

If `fetchAdd` returned the new value, a caller could not know if it was the third caller or the fourth caller. Two callers can see the same total.

All the functions in the family work in this way: `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`, `fetchMin`, `fetchMax`.

`swap` uses the same idea without arithmetic. It stores your value and returns the old value.

## Compare-and-swap is the general tool

No `fetchMul` exists. Also, no special operation exists for each problem. Instead, Zig has compare-and-swap. You can make each other operation on this page from compare-and-swap.

You give two values: the value that you think is there, and the new value. The swap occurs only if your first value is correct.

```zig
/// A multiplication needs a loop, because no `fetchMul` exists. Read the value,
/// calculate the new value, and swap only if no other thread changed it.
fn multiplyBy(counter: *Atomic(u32), factor: u32) void {
    var seen = counter.load(.monotonic);
    while (counter.cmpxchgWeak(seen, seen * factor, .monotonic, .monotonic)) |actual| {
        seen = actual;
    }
}
```

*Quoted from the source: `multiplyBy` from `snippets/03-standard-library/atomics.zig`.*

Read the loop condition carefully. It works in the opposite way to its appearance.

`cmpxchgWeak` returns an optional.

**Null means that the swap was successful.** A payload means that the swap failed. The payload is the value that was really there.

Thus `while (...) |actual|` loops while the swap *fails*. On each turn, the loop gives the new value back for one more attempt.

The program shows a failure directly. It guesses a wrong value on purpose:

```
cmpxchg against a wrong guess: 36
```

The counter was 36, the guess was 0, and the swap did not occur. The returned 36 is the value that the counter really holds.

`cmpxchgWeak` can fail spuriously, also when your guess is correct. This helps on ARM and RISC-V. On these CPUs, the function compiles to a load-linked/store-conditional pair, and a context switch can interrupt that pair. Thus, if the function can sometimes fail falsely, the loop is tighter.

In a retry loop, a spurious failure costs one more turn. When there is no loop and a false failure is wrong, use `cmpxchgStrong`.

## Ordering is an argument, not a fence

Each operation in this chapter has a second argument. The chapter did not explain that argument yet.

The argument has six values. The program prints them, weakest first:

```
orderings: .unordered .monotonic .acquire .release .acq_rel .seq_cst
```

The ordering does not change the result on the atomic variable. The ordering controls what the compiler and the CPU can do with **the other memory around the operation**.

The compiler and the CPU can both change the order of your instructions. Usually, you cannot see the difference, and it costs nothing. When a different thread watches, the order that the thread sees changes what your program does.

`.monotonic` is the weakest ordering that a read-modify-write accepts. It makes the operation indivisible. It gives no promise about the memory near the operation. That is correct for a statistics counter. For such a counter, you need the total at the end, and no other data depends on the time of each increment.

Use a stronger ordering when the atomic is a **signal about other data**.

`.seq_cst` is the strongest ordering. Use it when you are not sure. It is slower, but it is always correct.

No `@fence` builtin exists to use with these orderings. The ordering is an argument of each operation.

The compiler rejects the combinations that have no meaning. Thus you do not have to remember them:

```
c.fetchAdd(1, .unordered)   error: @atomicRmw atomic ordering must not be unordered
c.load(.release)            error: @atomicLoad atomic ordering must not be release or acq_rel
c.store(1, .acquire)        error: @atomicStore atomic ordering must not be acquire or acq_rel
```

A load cannot release, because it has no data to publish. A store cannot acquire, because it reads no data.

Compare-and-swap takes two orderings: one for the success path and one for the failure path. The failure ordering must not be stricter than the success ordering:

```
c.cmpxchgStrong(0, 1, .monotonic, .acquire)
error: failure atomic ordering must be no stricter than success
```

## Acquire and release are a pair

The most common pattern has the name *publishing*. It has two halves:

- One thread writes some data, and then it sets a flag.
- A different thread sees the flag, and then it reads the data.

```zig
/// The `.release` store promises that the write to `payload` is visible to
/// each reader that gets `true` from an `.acquire` load.
fn publish(payload: *u32, ready: *Atomic(bool), value: u32) void {
    payload.* = value;
    ready.store(true, .release);
}
```

*Quoted from the source: `publish` from `snippets/03-standard-library/atomics.zig`.*

The `.release` store makes a boundary. Each write above the store is visible to each thread that reads that `true` with `.acquire`.

```zig
/// The other half of the pair. Null means that the writer did not publish yet.
fn consume(payload: *const u32, ready: *const Atomic(bool)) ?u32 {
    if (!ready.load(.acquire)) return null;
    return payload.*;
}
```

*Quoted from the source: `consume` from `snippets/03-standard-library/atomics.zig`.*

```
before publish: null
after publish:  7
```

Without the pair, a reader can see `ready` as true and `payload` as zero. The two writes go to different addresses. Without the pair, the store to `payload` can become visible second.

That bug is very difficult to find. The problem lasts for a few nanoseconds, it depends on the CPU, and it does not occur under a debugger.

On this page, the two calls run on one thread. Thus the output shows only the pattern. On targets with real threads, the guarantee is true, and this pattern is the one to learn.

`.acq_rel` is for an operation that does the two at the same time. Such an operation is a read-modify-write, not a plain load or store.

## A lock is a compare-and-swap

Usual tools, for example locks, use atomics as their parts.

```zig
/// A lock is not a primitive. One compare-and-swap takes the lock, and one
/// ordered store releases the lock. The type needs nothing more.
/// `std.atomic.Mutex` is this type.
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
```

*Quoted from the source: `SpinLock` from `snippets/03-standard-library/atomics.zig`.*

Those ten lines are a mutex that works.

`tryLock` changes `unlocked` to `locked`, and it tells you if it was successful. Only one caller can see `unlocked` and take the lock. The reason is that only one compare-and-swap can succeed against a given value.

`unlock` stores `unlocked` with `.release`. The store publishes all that the holder did inside the critical section. The next thread that takes the lock sees those changes. These orderings are the pattern from the previous section, applied to the lock.

```
first tryLock:  true
second tryLock: false
after unlock:   true
```

`std.atomic.Mutex` is this type, in the standard library, at approximately this length.

But `std.atomic.Mutex` does not wait. A caller that fails to get the lock either spins or stops the attempt. A real mutex must put the thread to sleep, and then something must wake the thread. The operating system does that part.

For that reason, [`Io.Mutex`](https://www.ziglang.in/learn/concurrency/locks/) takes an `Io`. `SpinLock` does not take an `Io`.

## When a mutex is the better answer

Atomics are for one machine word. You cannot update two related fields atomically together.

If your invariant includes a counter and a pointer, no combination of atomic operations protects it. Use a lock for that case.

Lock-free code is also not always fast. A contended `fetchAdd` moves a cache line between cores on each call. Eight threads that all update one counter can be slower than eight threads that take a mutex.

`std.atomic.cache_line` exists for this problem. With it, you can put separate counters on separate cache lines when a profiler shows contention between them.

Select the tool in this way:

- For a counter, a flag, or a single pointer that you swap as a unit, use an atomic.
- For data that has an invariant, use [`Io.Mutex`](https://www.ziglang.in/learn/concurrency/locks/).
- Before you write your own lock-free structure, try [`Io.Queue`](https://www.ziglang.in/learn/concurrency/queues/).

## What moved

Two things on this page are different from an older tutorial.

`AtomicOrder` is now in `std.lang`. `std.lang` contains the declarations that the standard library shares with the compiler. `std.builtin` stays as an alias. Thus `std.builtin.AtomicOrder` still resolves, and the snippet on this page uses `std.lang.AtomicOrder`.

`@fence` does not exist now. Code that called `@fence` could almost always put the ordering on the operation instead. Now the operation is the only place for an ordering.

The builtins are still available under the wrapper. `std.atomic.Value` calls `@atomicLoad`, `@atomicStore`, `@atomicRmw` and `@cmpxchgStrong`. `SpinLock` above uses two of these builtins directly, because `Value` is not designed for an `enum(u8)`.

Next: [Threads](https://www.ziglang.in/learn/concurrency/threads/) shows the real threads that these guarantees are for. [Locks and Semaphores](https://www.ziglang.in/learn/concurrency/locks/) shows the tools to prefer over atomics.
