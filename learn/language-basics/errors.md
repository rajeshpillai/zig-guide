# Errors

> Errors are values in a union, not exceptions.

Zig has no exceptions. A function that can fail returns an **error union**. You write it as `E!T`. The value is an error from the set `E`, or a `T`.

```zig
const std = @import("std");
const expect = std.testing.expect;

const FileOpenError = error{
    AccessDenied,
    OutOfMemory,
    FileNotFound,
};

// Error sets coerce into supersets. Thus a function that declares a wider
// set can return a narrow error.
const AllocationError = error{OutOfMemory};

test "error set coercion" {
    const err: FileOpenError = AllocationError.OutOfMemory;
    try expect(err == FileOpenError.OutOfMemory);
}

fn failingFunction() error{Oops}!void {
    return error.Oops;
}

test "catch supplies a fallback" {
    // `!u8` is a short form of "an inferred error set, or u8".
    const parsed = std.fmt.parseInt(u8, "not a number", 10) catch 0;
    try expect(parsed == 0);
}

test "try propagates" {
    // `try x` is `x catch |err| return err`.
    try std.testing.expectError(error.Oops, failingFunction());
}

test "capture the error in catch" {
    var captured: anyerror = undefined;
    failingFunction() catch |err| {
        captured = err;
    };
    try expect(captured == error.Oops);
}

fn parseOrDefault(text: []const u8) u32 {
    // `if` can also unwrap an error union, with `else |err|`.
    if (std.fmt.parseInt(u32, text, 10)) |value| {
        return value;
    } else |_| {
        return 0;
    }
}

test "if on an error union" {
    try expect(parseOrDefault("42") == 42);
    try expect(parseOrDefault("abc") == 0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.errors`)*

## Error sets are types

```zig
const FileOpenError = error{ AccessDenied, OutOfMemory, FileNotFound };
```

A narrow set coerces into a wider set. Thus a function that returns `FileOpenError` can call a function that returns `error{OutOfMemory}`, and it needs no extra code.

`anyerror` is the set of all errors. It is convenient, but it removes the list of possible errors. That list is the reason that error sets are useful.

You combine sets with `||`. A function that calls two subsystems uses `||` to declare that it can fail in the two ways:

```zig
const Error = ParseError || std.Io.Reader.Error;
```

If you write `!T` with no set, the compiler infers the set from each error that the body can make. Inside a program, this is the correct default. At the public boundary of a library, it is the wrong default. The inferred set is part of your interface, and the set changes without a warning when the body changes.

An error is only a value with a name. It does not contain a payload, a message or a stack trace. Thus you can compare errors, use them in a `switch`, and return them at no cost. When a failure needs detail, put the detail in a place where the caller can ask for it. Do not put it into the error.

## Four ways to handle an error

| Form | Meaning |
| --- | --- |
| `try x` | unwrap, or return the error to my caller |
| `x catch fallback` | unwrap, or use this value instead |
| `x catch \|err\| { ... }` | unwrap, or handle the error here |
| `if (x) \|v\| ... else \|err\| ...` | branch on both outcomes |

`try` is the most common form, and it is *only* a short form of `x catch |err|
return err`.

To handle some errors and return the other errors, use a `switch` inside the `catch`. The `switch` must have a prong for each error in the set. Thus, if a function that you call gets a new failure mode, each caller that lists the errors gets a compile error:

```zig
const config = load(path) catch |err| switch (err) {
    error.FileNotFound => Config.default,
    else => return err,
};
```

`catch unreachable` asserts that a call cannot fail. Safety builds check the assertion. In ReleaseFast, a failure is undefined behaviour.

Use `catch unreachable` only where the code shows, in the same place, why the call cannot fail. Do not use it to avoid an error that the signature says can occur.

## Errors that need cleanup

`errdefer` runs only on the error path. With `errdefer`, an initialiser with many steps can clean up correctly, and you do not copy the cleanup into each `catch`. [Defer](https://www.ziglang.in/learn/language-basics/defer/) explains it.

`try` can return from the middle of a function. `errdefer` is the cleanup that you prepare before that return can occur.

## Find where an error comes from

An error contains no stack. Thus, in Debug and ReleaseSafe, Zig makes a separate **error return trace**. If an error goes out of `main`, Zig prints the chain of `try` sites that the error went through.

This trace gives you the same information as a stack trace, and often more. It shows where the code made the error, not only where the code saw the error. In ReleaseFast, Zig does not make the trace, thus the trace has no cost there.

To write an error to a [log](https://www.ziglang.in/learn/standard-library/logging/) yourself, use `@errorName(err)`. It gives the name as a string. The `{!}` format specifier prints an error union directly, as `error.FileNotFound`.

## Why error unions are better than exceptions

The failure paths are in the type signature and in the control flow that you can see. No line has a hidden second exit, and no hidden code unwinds the stack. Each exit is visible. Thus `defer` is necessary for cleanup, and `defer` is also sufficient.

With exceptions, the main path of the code stays clean, and the code that handles errors is in a different place. Error unions put a `try` on each call that can fail. This adds noise. In return, each `try` shows the reader a place where the function can return early. Also, a function cannot fail in a way that its signature does not declare.
