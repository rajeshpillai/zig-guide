# Assignment

> const by default, and var only when you must change the value.

Zig has two ways to declare a value. The default is the immutable one.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "const and var" {
    const constant: i32 = 5; // cannot get a new value
    var variable: u32 = 5000; // can get a new value
    variable += 1;

    // The compiler can infer the type from the value.
    const inferred_constant = @as(i32, 5);
    var inferred_variable = @as(u32, 5000);
    inferred_variable += 1;

    try expect(constant == 5);
    try expect(variable == 5001);
    try expect(inferred_constant == 5);
    try expect(inferred_variable == 5001);
}

test "undefined leaves memory uninitialised" {
    // `undefined` means "I will assign this before I read it". A read before
    // the assignment is illegal behaviour. The value is not always zero.
    var x: i32 = undefined;
    x = 7;
    try expect(x == 7);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.assignment`)*

## Use `const` unless you must change the value

`const` is not a hint. The compiler enforces it. A new assignment to a `const` is a compile error. A `var` that you never change is also a compile error.

If you know C, the second rule can surprise you. Because of this rule, a `var` in Zig always means *this value changes*.

This rule helps when you read code that you do not know. For each `const`, you can find its single assignment and stop. For each `var`, you must follow all of its changes. Some languages use `var` as the default and allow a `var` that never changes. In those languages, the difference gives no information, because most variables are `var` only from habit.

The same rule applies to unused declarations. They are errors, not warnings. Zig has no lint level to change here. If the code does not use a variable now, the code does not build until you remove the variable.

## `const` is about the binding, not the contents

A `const` slice or pointer prevents a new assignment to the variable. It does not prevent a write through the slice or pointer:

```zig
const items = try allocator.alloc(u8, 4);
items[0] = 1;        // fine: items still points at the same memory
items = other;       // error: cannot assign to constant
```

The element type controls the write. You cannot write through a `[]const u8`. You can write through a `[]u8`, and the `const` or `var` of the variable does not change this.

These are two separate questions. The answer to one question tells you nothing about the other question. [Pointers](https://www.ziglang.in/learn/language-basics/pointers/) has the same split for `*T`.

## The compiler infers types, but literals have no size

Type annotations are optional when the compiler can infer the type. `@as(i32, 5)` is an explicit cast. The snippet uses it to give a fixed type to a value that would otherwise be an untyped `comptime_int`.

This explains an error message that you will see early. A bare `5` is not an `i32`. It is a `comptime_int`, an integer of arbitrary precision that exists only during compilation. It coerces to the type that the context needs. When there is no context, it has no type to coerce to:

```zig
const a = 5;             // comptime_int, fine as long as it stays comptime
var b = 5;               // error: must be const or comptime
var c: u8 = 5;           // fine: the annotation gives the literal a size
```

A `var` must be in memory at runtime, and memory cannot hold a value of arbitrary precision. The fix is always the same: write the size that you want.

## `undefined` is a promise, not a value

```zig
var x: i32 = undefined;
```

This line means "I will write to this variable before I read it". It does **not** mean zero. If you read `x` before an assignment, the result is illegal behaviour.

In a build with safety checks, Zig fills the memory with `0xaa` bytes. Thus the mistake is easy to see. The value does not look like a normal value.

Zig selects `0xaa` on purpose:

- As a pointer, the value is very far out of range.
- As a length, the value is very large.
- As a float, the value is a signalling NaN.
- As a signed integer, the value is negative, which is easy to see.

Thus a bug that reads uninitialised memory usually gives a value that you see. It does not give a zero that looks correct and that is by chance the right answer in your test.

In ReleaseFast, Zig does not fill the memory. The memory contains the old data. Thus use `undefined` for buffers that you fill immediately. When you want zero, write `var x: i32 = 0`.
