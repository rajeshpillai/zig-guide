# Comptime

> Usual Zig code that the compiler runs.

`comptime` is the Zig solution for templates, macros, generics, reflection and constant folding. It uses one mechanism for all of them: **the compiler runs usual Zig code at compile time, and types are values there.**

```zig
const std = @import("std");
const expect = std.testing.expect;

fn fibonacci(n: u32) u32 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

// A generic function is only a function that takes a `type` parameter.
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
    // `comptime` makes the compiler evaluate the call during compilation.
    // The binary contains the answer, not the recursion.
    const small = comptime fibonacci(10);
    try expect(small == 55);
    try expect(@TypeOf(small) == u32);
}

test "the branch quota is a real limit" {
    // Comptime evaluation has a limit of 1000 backwards branches. Thus a
    // calculation that does not stop makes the build fail, and the compiler
    // does not hang. fibonacci(20) needs more, thus increase the limit.
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

    // A different T makes a different type.
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

Zig has no second language for this. The code that runs during compilation is the same Zig, with the same syntax and the same standard library functions. To debug it, you read it. You do not expand a macro.

C++ templates, C macros and the declarative macros of Rust are each a separate language with separate rules. You cannot step through any of them.

## Types are values

A `type` is a usual comptime value. Because of this one fact, Zig does not need a separate language for generics:

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
```

`comptime T: type` says that the compiler must know this parameter at compile time. The compiler makes a separately compiled function for each different `T`. The name of this process is monomorphisation, and it needs no special syntax.

Values that are not types can also be `comptime`. A function uses such a value to specialise on a configuration instead of a type:

```zig
fn hash(comptime seed: u64, data: []const u8) u64 { ... }
```

Each call with a different `seed` gets its own compiled copy, and the compiler folds the constant into that copy. These copies are also the cost. `comptime` parameters multiply the quantity of generated code. Use them for parameters that have a small number of different values, not for parameters that have a thousand values.

## Generic types are functions that return types

```zig
fn List(comptime T: type) type {
    return struct { items: []T, ... };
}
```

`List(i32)` and `List(u8)` are different types. `std.ArrayList` and `std.HashMap` are usual functions, the same as this one. The standard library gets no special syntax that you cannot use yourself.

When you call the same function with the same arguments, you get the same type. You do not get a new type for each call. Thus `List(u8)` in two different files is one type.

## What can and cannot run at compile time

Code that is pure computation can run at compile time. Examples are arithmetic, control flow, array construction, a walk over the fields of a type, and string formatting.

Code that touches the outside world cannot run at compile time. Comptime code cannot read a file, read the clock, allocate from a runtime allocator, or call C.

When you use a value that the compiler knows, the compiler evaluates the code, with or without `comptime`. The keyword makes the evaluation necessary. `comptime` before an expression tells the compiler to evaluate the expression now. If the compiler cannot, the build fails. Without the keyword, such code runs at runtime and you get no message. With the keyword, you get an error.

A related tool is `@compileError`. When the compiler reaches a branch with `@compileError`, the build fails with your message. With `@typeInfo`, a generic function can use `@compileError` to refuse a type that it cannot use. Then the user gets your message, not an error from inside the function body.

## The branch quota

Comptime evaluation has a limit of **1000 backwards branches**. Thus an accidental infinite loop makes the build fail, and the compiler does not hang. Real work is often more than this limit:

```zig
@setEvalBranchQuota(100_000);
const result = comptime fibonacci(20);
```

An increase of the quota is normal. If you must increase the quota to a very large number, the work possibly belongs at runtime.

## The work that comptime saves

When the compiler calculates something at comptime, the binary contains only the result, not the code. The compiler compares format strings with their arguments. It makes lookup tables. It removes dead configuration branches fully.

A check of a configuration value that the compiler knows does not become a branch in the output. Thus the CPU never has to predict the branch. A library can therefore have a dozen options, and none of the options costs a test at runtime. You can write a debug-only code path as usual code. You do not have to hide it behind conditional compilation.

The limit to remember is compile time. Each table that you generate and each type that you make is work for the compiler on each build. You can write a program that is fast at runtime and very slow to build. A comptime calculation that needs a large branch quota is a warning sign of this problem.

[Comptime](https://www.ziglang.in/learn/metaprogramming/) is a full section on this subject. It builds a lookup table, reads the fields of a type and makes new types, with one program for each chapter.
