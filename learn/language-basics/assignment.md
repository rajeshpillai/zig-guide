# Assignment

> const by default, var only when you must mutate.

Zig has two ways to introduce a value, and the default is the immutable one.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "const and var" {
    const constant: i32 = 5; // may not be reassigned
    var variable: u32 = 5000; // may be reassigned
    variable += 1;

    // The type can be inferred from the value.
    const inferred_constant = @as(i32, 5);
    var inferred_variable = @as(u32, 5000);
    inferred_variable += 1;

    try expect(constant == 5);
    try expect(variable == 5001);
    try expect(inferred_constant == 5);
    try expect(inferred_variable == 5001);
}

test "undefined leaves memory uninitialised" {
    // `undefined` means "I will assign this before I read it". Reading it
    // first is illegal behaviour, not a guaranteed zero.
    var x: i32 = undefined;
    x = 7;
    try expect(x == 7);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.assignment`)*

## `const` unless proven otherwise

`const` is not a hint: it is enforced. Reassigning a `const` is a compile
error, and so is declaring a `var` you never mutate. That second rule
surprises people coming from C, but it means a `var` in Zig is a real signal:
*this changes*.

The payoff shows up when reading unfamiliar code. Every `const` is a value you
can follow to its single assignment and stop. Every `var` is one you have to
trace. In a language where `var` is the default and unused mutability is
allowed, that distinction carries no information, because most `var`s are only
`var` out of habit.

The same applies to unused declarations, which are errors rather than
warnings. Zig has no lint level to tune here: code that no longer uses a
variable does not build until the variable goes.

## `const` is about the binding, not the contents

A `const` slice or pointer stops you reassigning the variable. It does not
stop you writing through it:

```zig
const items = try allocator.alloc(u8, 4);
items[0] = 1;        // fine: items still points at the same memory
items = other;       // error: cannot assign to constant
```

What blocks the write is the element type: `[]const u8` cannot be written
through, `[]u8` can, regardless of whether the variable holding it is `const`.
Two independent questions, and the answer to one says nothing about the other.
[Pointers](https://www.ziglang.in/learn/language-basics/pointers/) has the same split for `*T`.

## Types are inferred, but literals have no size

Type annotations are optional when the compiler can infer them. `@as(i32, 5)`
is an explicit cast used here to pin down what would otherwise be an untyped
`comptime_int`.

That distinction is worth understanding early, because it explains a class of
error message. A bare `5` is not an `i32`; it is a `comptime_int`, an
arbitrary precision integer that exists only during compilation. It coerces to
whatever the context needs, and when there is no context, there is nothing to
coerce to:

```zig
const a = 5;             // comptime_int, fine as long as it stays comptime
var b = 5;               // error: must be const or comptime
var c: u8 = 5;           // fine: the annotation gives the literal a size
```

A `var` has to live in memory at runtime, and "arbitrary precision" is not a
thing memory can hold. The fix is always the same: say what size you meant.

## `undefined` is a promise, not a value

```zig
var x: i32 = undefined;
```

This says "I will write to this before I read it". It does **not** mean zero.
Reading `x` before assigning is illegal behaviour. In a safety-enabled build
Zig fills the memory with `0xaa` bytes so the mistake is loud rather than
silently plausible.

The `0xaa` choice is deliberate. As a pointer it is wildly out of range. As a
length it is enormous. As a float it is a signalling NaN. As a small integer
it is a suspiciously round negative number. A bug that reads uninitialised
memory tends to produce a value you notice rather than a plausible zero that
happens to be the right answer in your test.

In ReleaseFast the fill is gone and the memory holds whatever was there
before. That is why `undefined` is reserved for buffers you are about to fill,
and why `var x: i32 = 0` is the right thing to write when you actually meant
zero.
