# Functions

> Immutable parameters and explicit discards.

Zig function parameters are constant. If a function returns a value that is not `void`, and you do not use the value, the result is a compile error. Thus you write a discard explicitly: `_ = addFive(1);`.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn addFive(x: u32) u32 {
    // Parameters are const. `x += 5` here would not compile.
    return x + 5;
}

fn fibonacci(n: u16) u16 {
    if (n == 0 or n == 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

test "calling a function" {
    const y = addFive(0);
    try expect(@TypeOf(y) == u32);
    try expect(y == 5);
}

test "recursion" {
    try expect(fibonacci(10) == 55);
}

test "values must be used" {
    // In Zig, an unused value is a compile error, not a warning. Use `_ =`
    // to discard a value explicitly.
    _ = addFive(1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.functions`)*

## Parameters are constant

For example, this code does not compile:

```zig
fn addFive(x: u32) u32 {
    x += 5;      // error: cannot assign to constant
    return x;
}
```

If you want a mutable local, make one. The benefit is that a parameter always has the value from the call site, through all of the function body. In a long function, `x` on line 60 is the `x` that the caller gave. You do not have to read the 59 lines above to be sure.

To let the function change a value of the caller, take a pointer, and write the pointer in the type:

```zig
fn addFiveInPlace(x: *u32) void {
    x.* += 5;
}
```

Now the change is visible at the call site as `addFiveInPlace(&n)`. Zig has no reference parameters that write to the caller without a visible sign.

## The compiler decides how to pass arguments

A parameter is a value. But the compiler decides if it copies the value or passes a pointer to it. The compiler uses the type and the calling convention of the target to decide.

When you pass a large struct, the compiler does not always copy it. Parameters are immutable. Thus the code inside the function cannot see which method the compiler used, and the compiler can use either method.

## Unused values are errors

Zig has no "unused variable" *warning*, because an unused variable is an error:

```
error: value of type 'u32' ignored
note: all non-void values must be used
```

A discard is explicit:

```zig
_ = addFive(1);
```

This rule finds the case where you called a function for its result, but forgot to use the result. The rule also applies to unused locals and parameters. Thus `_ = name;` often occurs in code that is not complete. When you refactor, the compiler does not let you keep a variable that you do not use now.

A function that returns `void` is the exception. It gives no value to use, thus a bare call is correct.

## Generic functions are usual functions

The call site supplies the type of an `anytype` parameter. The compiler compiles the function one time for each set of types that the callers use:

```zig
fn maxOf(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a else b;
}
```

`maxOf(@as(u8, 3), 5)` and `maxOf(@as(f32, 1.5), 0.5)` both work, and each call gets its own machine code. Zig has no separate syntax for generics, such as a type parameter list or a constraint language.

A type is a value at compile time. Thus a function that takes types is only a function. The standard library uses this idea in many places. [comptime](https://www.ziglang.in/learn/language-basics/comptime/) explains it in detail.

The cost is that errors occur when a caller uses the function with concrete types, not when you define the function. For example, a function calls `a.len` on its `anytype` parameter. The function compiles correctly until a caller passes an integer. Then the error message points inside your function, not at the call of the other person.

## Function pointers

A function is not a pointer, but you can take a pointer to a function:

```zig
const p: *const fn (u8) u8 = &addOne;
```

The type is `*const fn` and not `fn`, because the pointer can change, not the code. A callback field in a struct holds this type of pointer.

The interfaces in the standard library also use function pointers. An interface is a pointer to some state, plus a table of function pointers that know how to use that state.

## Recursion and the stack

The `fibonacci` function above is recursive. But Zig cannot always prove a limit on the use of the stack. For deep recursion, or recursion that depends on the input, an explicit stack or a loop is the safer selection. Zig does not guarantee automatic tail calls.

You cannot catch this failure. A stack overflow is a crash, not a Zig error value. How clearly the crash shows depends on the platform. When the input sets the depth of the recursion, check that depth as you check all other input.
