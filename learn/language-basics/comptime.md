# Comptime

> Ordinary Zig, executed by the compiler.

`comptime` is Zig's answer to templates, macros, generics, reflection, and
constant folding, all with one mechanism: **run normal Zig at compile time,
where types are values.**

```zig
const std = @import("std");
const expect = std.testing.expect;

fn fibonacci(n: u32) u32 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

// A generic function is just one that takes a `type` parameter.
fn List(comptime T: type) type {
    return struct {
        items: []T,

        pub fn first(self: @This()) ?T {
            return if (self.items.len == 0) null else self.items[0];
        }
    };
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

test "evaluate at compile time" {
    // `comptime` forces evaluation during compilation; the binary contains
    // the answer, not the recursion.
    const small = comptime fibonacci(10);
    try expect(small == 55);
    try expect(@TypeOf(small) == u32);
}

test "the branch quota is a real limit" {
    // Comptime evaluation is capped at 1000 backwards branches so a runaway
    // computation fails the build instead of hanging the compiler.
    // fibonacci(20) blows past that; raise the ceiling deliberately.
    @setEvalBranchQuota(100_000);
    const result = comptime fibonacci(20);
    try expect(result == 6765);
}

test "types are comptime values" {
    const T = u16;
    const value: T = 300;
    try expect(@TypeOf(value) == u16);
}

test "generic data structure" {
    var backing = [_]i32{ 10, 20 };
    const list = List(i32){ .items = &backing };
    try expect(list.first().? == 10);

    // A different T produces a genuinely different type.
    try expect(List(i32) != List(u8));
}

test "generic function" {
    try expect(max(u8, 1, 2) == 2);
    try expect(max(f32, 1.5, 0.5) == 1.5);
}

test "comptime blocks can assert" {
    comptime {
        // A failed comptime assert is a compile error, not a test failure.
        std.debug.assert(@sizeOf(u32) == 4);
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.comptime`)*

There is no second language here. The code that runs during compilation is the
same Zig, with the same syntax and the same standard library functions. You
debug it by reading it, not by expanding a macro. That is the whole claim, and
it is what makes the feature worth having. C++ templates, C macros and Rust's
declarative macros are each a separate language with separate rules. None of
them can be stepped through.

## Types are values

A `type` is an ordinary comptime value. That single fact removes the need for
a separate generics language:

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
```

`comptime T: type` says this parameter must be known at compile time. Each
distinct `T` produces a separately compiled function: monomorphisation, with
no special syntax.

Values other than types can be `comptime` too, and that is how a function
specialises on a configuration rather than a type:

```zig
fn hash(comptime seed: u64, data: []const u8) u64 { ... }
```

Every call with a different `seed` gets its own compiled copy with the
constant folded in. That is also the cost. `comptime` parameters multiply the
amount of code generated. They belong on things that take a handful of
distinct values, not on things that take a thousand.

## Generic types are functions returning types

```zig
fn List(comptime T: type) type {
    return struct { items: []T, ... };
}
```

`List(i32)` and `List(u8)` are genuinely different types. `std.ArrayList` and
`std.HashMap` are ordinary functions like this one. Nothing in the standard
library gets privileged syntax you cannot use yourself.

Calling the same function with the same arguments gives the same type back,
not a new one each time. That is what makes `List(u8)` in two different files
refer to one thing.

## What can and cannot run at compile time

Anything that is pure computation can: arithmetic, control flow, building
arrays, walking a type's fields, formatting a string. Anything that touches
the outside world cannot. There is no reading a file, no clock, no allocation
from a runtime allocator, and no calling into C.

When you use a value the compiler already knows, evaluation happens whether or
not you wrote `comptime`. The keyword is for forcing the issue. `comptime`
before an expression demands that it be evaluated now, and fails the build if
it cannot. That turns a silent fallback to runtime into an error.

The mirror image is `@compileError`, which fails the build with your message
when a branch is reached during compilation. Combined with `@typeInfo`, that
is how a generic function rejects a type it cannot handle with a sentence
instead of an error inside its body.

## The branch quota

Comptime evaluation is capped at **1000 backwards branches**, so an accidental
infinite loop fails the build instead of hanging the compiler. Real work often
exceeds it:

```zig
@setEvalBranchQuota(100_000);
const result = comptime fibonacci(20);
```

Raising it is normal; needing to raise it to something absurd is a hint that
the work belongs at runtime.

## Where it saves you work

Anything computed at comptime is not in the binary as code, only as its
result. Format strings are checked against their arguments, lookup tables are
generated, and dead configuration branches disappear entirely.

The last one is worth spelling out. A check against a comptime-known
configuration value is not a branch the CPU predicts, it is a branch that does
not exist in the output. So a library can offer a dozen options without any of
them costing a test at runtime. A debug-only code path can be written
normally, rather than hidden behind conditional compilation.

The limit to keep in mind is compile time. Every table you generate and every
type you create is work the compiler does on every build. It is possible to
write a program that is fast at runtime and painfully slow to build. When a
comptime computation starts needing a large branch quota, that is the signal.
