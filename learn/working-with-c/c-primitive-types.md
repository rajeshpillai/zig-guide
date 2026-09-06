# C Primitive Types

> Types whose width follows the target's C ABI.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "c types are separate from fixed-width ones" {
    // `c_int` is whatever `int` is on this target. Use it only at the
    // C boundary, and use i32/u64/etc everywhere else.
    try expect(@sizeOf(c_int) == 4);
    try expect(@sizeOf(c_char) == 1);
    try expect(c_int != i32); // distinct types, even at the same size
}

test "c_long varies by target" {
    // 4 bytes on wasm32 and Windows, 8 on 64-bit Linux. This is exactly
    // why the type exists rather than hardcoding i64.
    try expect(@sizeOf(c_long) == 4); // wasm32
}

test "converting at the boundary" {
    const n: i32 = 42;
    const c: c_int = @intCast(n);
    try expect(c == 42);
}

test "the C ABI integer for pointers" {
    try expect(@sizeOf(usize) == @sizeOf(*anyopaque));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`05-working-with-c.c-primitives`)*

Zig provides `c_char`, `c_short`, `c_int`, `c_long`, `c_longlong`, their
`unsigned` counterparts, and `c_longdouble`. Their sizes are whatever the
target's C ABI says.

## Why not just use `i32`?

Because `long` is not one size. It is 8 bytes on 64-bit Linux and macOS, 4
bytes on Windows and on wasm32. Code that hardcodes `i64` for a C `long` is
correct on one platform and silently wrong on another, the kind of bug that
appears only after a port.

`c_int` and `i32` are **distinct types** even when they are the same size, so
the compiler will not let you conflate them by accident.

## Keep them at the boundary

Convert at the edge and use fixed-width types inside:

```zig
export fn process(count: c_int) callconv(.c) void {
    const n: u32 = @intCast(count);   // now in Zig's world
    ...
}
```

Threading `c_int` through your whole program spreads a target-dependent
assumption everywhere.

## `anyopaque`

`anyopaque` is Zig's `void` in the C sense: the pointee type of `void*`. So
C's `void *ptr` becomes `*anyopaque`, and C's `void f(void)` returns Zig's
`void`. The two meanings of C's `void` are separated.

For handles you control, prefer a distinct [`opaque
{}`](https://www.ziglang.in/learn/language-basics/opaque/) type over `*anyopaque`: it keeps
different handle kinds from being interchangeable.

## What C guarantees, and what it does not

C does not specify the size of its integer types. It specifies minimum ranges
and an ordering, and the actual widths are the platform's business, recorded
in a document called the ABI. That is why the table below has three answers
rather than one:

| C type | 64-bit Linux/macOS | 64-bit Windows | wasm32 |
| --- | --- | --- | --- |
| `int` | 4 | 4 | 4 |
| `long` | 8 | **4** | **4** |
| `long long` | 8 | 8 | 8 |
| `size_t` | 8 | 8 | **4** |
| pointer | 8 | 8 | **4** |

`long` is the one that catches people, because the two most common desktop
platforms disagree about it. `c_long` gets this right on every target Zig
supports, which is the entire reason it exists.

`c_char` has a second problem on top of the width: whether it is signed is
also platform-defined, and it differs between x86 and ARM Linux. Zig models
that too, which is why `c_char` is its own type rather than an alias for `i8`
or `u8`.

## Keep them at the boundary

Convert at the edge and use fixed-width types inside:

```zig
export fn process(count: c_int) callconv(.c) void {
    const n: u32 = @intCast(count);   // now in Zig's world
    ...
}
```

Threading `c_int` through your whole program spreads a target-dependent
assumption everywhere.

The conversion is also where the validation belongs. A `c_int` from C can be
negative, and if your code treats it as a count, that is the line to reject it
on. `@intCast` panics in a safety build when the value does not fit, which is
better than proceeding. But at a boundary where the value came from outside,
an explicit check producing an error is better still.

## `anyopaque`

`anyopaque` is Zig's `void` in the C sense: the pointee type of `void*`. So
C's `void *ptr` becomes `*anyopaque`, and C's `void f(void)` returns Zig's
`void`. The two meanings of C's `void` are separated.

That separation is worth noticing as an example of the general pattern here. C
reuses one keyword for "nothing" and for "something whose type I am not
telling you", and code has to work out which from context. Zig gives them
different names, and the ambiguity disappears at the point of translation
rather than being carried into your program.

Similarly, C's `void*` is both "a pointer to unknown data" and the generic
pointer everything converts to. In Zig, `*anyopaque` is the first, and the
converting is done with `@ptrCast`, visibly, where you can see it.
