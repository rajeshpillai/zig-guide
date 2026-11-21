# C Primitive Types

> Types whose width follows the target's C ABI.

In Zig, a C `int` is `c_int` and a C `long` is `c_long`. The sizes of these
types follow the C ABI of the target. Use them at the C boundary, because
`long` is 8 bytes on 64-bit Linux and 4 bytes on Windows.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "c types are separate from fixed-width ones" {
    // `c_int` has the size of `int` on this target. Use `c_int` only at the
    // C boundary. In all other places, use i32, u64 and the other fixed types.
    try expect(@sizeOf(c_int) == 4);
    try expect(@sizeOf(c_char) == 1);
    try expect(c_int != i32); // different types, also at the same size
}

test "c_long varies by target" {
    // 4 bytes on wasm32 and Windows, 8 bytes on 64-bit Linux. The type
    // exists because of this difference. Thus do not hardcode i64.
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

Zig has these C types:

- `c_char`, `c_short`, `c_int`, `c_long` and `c_longlong`.
- An `unsigned` type for each of these types except `c_char`. There is no
  `c_uchar`.
- `c_longdouble`.

The C ABI of the target sets the size of each type.

## Why not use `i32`

A C `long` does not have one size. If code uses `i64` for a C `long`, the code
is correct on one platform and wrong on a different platform. Nothing tells
you about the error. A bug of this type appears only after a port.

`c_int` and `i32` are **different types**, also when they have the same size.
Thus the compiler does not let you use one type for the other by accident.

## What C guarantees, and what it does not

C does not specify the size of its integer types. C specifies minimum ranges
and an order of sizes. The platform sets the actual widths, and a document
called the ABI records them. For this reason, the table below has three
answers and not one:

| C type | 64-bit Linux/macOS | 64-bit Windows | wasm32 |
| --- | --- | --- | --- |
| `int` | 4 | 4 | 4 |
| `long` | 8 | **4** | **4** |
| `long long` | 8 | 8 | 8 |
| `size_t` | 8 | 8 | **4** |
| pointer | 8 | 8 | **4** |

`long` causes the most problems, because the two most common desktop
platforms do not agree about its size. `c_long` gives the correct size on all
targets that Zig supports.

`c_char` has a second problem in addition to the width. The platform also
decides if `c_char` is signed or unsigned, and the answer is different on x86
Linux and ARM Linux. Zig also models this difference. For this reason,
`c_char` is a separate type, and not an alias for `i8` or `u8`.

## Keep the C types at the boundary

Convert at the edge, and use fixed-width types inside the program:

```zig
export fn process(count: c_int) callconv(.c) void {
    const n: u32 = @intCast(count);   // now in Zig's world
    ...
}
```

If you use `c_int` in all of your program, an assumption that depends on the
target spreads to all parts of the program.

The conversion is also the correct place for validation. A `c_int` from C can
be negative. If your code uses the value as a count, reject a negative value
on the line of the conversion. In a safety build, `@intCast` panics when the
value does not fit. A panic is better than a program that continues. But at a
boundary where the value comes from outside, an explicit check that returns
an error is better again.

## `anyopaque`

`anyopaque` is Zig's `void` in the C sense: the type that a `void*` points
to. Thus C's `void *ptr` becomes `*anyopaque`, and C's `void f(void)` returns
Zig's `void`. Zig keeps the two meanings of C's `void` separate.

The same rule applies in other places. C uses one keyword for "nothing", and
also for "something whose type I do not tell you". Code must use the context
to find which meaning is correct. Zig gives the two meanings different names.
Thus the ambiguity stops at the point of translation. Your program does not
get the ambiguity.

In the same way, C's `void*` is "a pointer to unknown data". It is also the
generic pointer that all other pointers convert to. In Zig, `*anyopaque` has
only the first meaning. For the conversion, you use `@ptrCast`, and you can
see the conversion in the code.

For handles that you control, use a separate [`opaque
{}`](https://www.ziglang.in/learn/language-basics/opaque/) type, not `*anyopaque`. A separate type
prevents the use of one type of handle in place of a different type of
handle.
