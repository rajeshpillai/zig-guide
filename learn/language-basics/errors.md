# Errors

> Errors are values in a union, not exceptions.

Zig has no exceptions. A function that can fail returns an **error union**,
written `E!T`: either an error from set `E`, or a `T`.

```zig
const std = @import("std");
const expect = std.testing.expect;

const FileOpenError = error{
    AccessDenied,
    OutOfMemory,
    FileNotFound,
};

// Error sets coerce into supersets, so a narrow error can be returned
// from a function that declares a wider set.
const AllocationError = error{OutOfMemory};

test "error set coercion" {
    const err: FileOpenError = AllocationError.OutOfMemory;
    try expect(err == FileOpenError.OutOfMemory);
}

fn failingFunction() error{Oops}!void {
    return error.Oops;
}

test "catch supplies a fallback" {
    // `!u8` is shorthand for "some inferred error set, or u8".
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
    // `if` can unwrap an error union too, with `else |err|`.
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

A narrow set coerces into a wider one, so a function returning
`error{OutOfMemory}` can be called from one returning `FileOpenError` with no
extra code. `anyerror` is the set of all errors. It is convenient, but it
throws away the list of possible errors, which is what makes error sets
useful.

Sets combine with `||`, which is how a function that calls two subsystems
declares that it can fail in either way:

```zig
const Error = ParseError || std.Io.Reader.Error;
```

Writing `!T` with no set at all asks the compiler to infer it from every error
the body can produce. Inside a program, that is the right default. It is the
wrong default at a library's public boundary,
because the inferred set is part of your interface and changes silently when
the body changes.

An error is just a value with a name. It does not carry a payload, a message
or a stack trace. Because of this, you can compare errors, switch on them, and
return them at no cost. When a failure needs detail, put the detail somewhere
the caller can ask for it, not into the error.

## Four ways to handle one

| Form | Meaning |
| --- | --- |
| `try x` | unwrap, or return the error to my caller |
| `x catch fallback` | unwrap, or use this value instead |
| `x catch \|err\| { ... }` | unwrap, or handle the error here |
| `if (x) \|v\| ... else \|err\| ...` | branch on both outcomes |

`try` is the most common form, and it is *only* shorthand: `x catch |err|
return err`.

To handle some errors and pass on the rest, switch inside the `catch`. The
switch is exhaustive over the error set, so adding a new failure mode to a
function you call becomes a compile error in every caller that was enumerating
them:

```zig
const config = load(path) catch |err| switch (err) {
    error.FileNotFound => Config.default,
    else => return err,
};
```

`catch unreachable` asserts a call cannot fail. It is checked in safety builds
and undefined behaviour in ReleaseFast. Use it where the reason the call
cannot fail is visible right there in the code. Do not use it to avoid
handling an error the signature says can happen.

## Errors that need cleanup

`errdefer` runs only on the error path. With it, a multi-step initialiser
cleans up correctly without copying the cleanup into every `catch`. It is
covered in [defer](https://www.ziglang.in/learn/language-basics/defer/). `try` can return from the
middle of a function. `errdefer` is the cleanup you set up in advance for that
case.

## Finding out where it came from

Because an error carries no stack, Zig builds an **error return trace**
separately in Debug and ReleaseSafe. Letting an error escape `main` prints the
chain of `try` sites it passed through on the way up. This gives you what a
stack trace would, and often more: it shows where the error was produced, not
where it was noticed. It costs nothing in ReleaseFast, where
the trace is not built at all.

For [logging](https://www.ziglang.in/learn/standard-library/logging/) one yourself, `@errorName(err)` gives the name as a string, and
the `{!}` format specifier prints an error union directly, as
`error.FileNotFound`.

## Why this beats exceptions

The failure paths are in the type signature and in the control flow you can
see. No line has a hidden second exit, and nothing unwinds the stack out of
sight. Because every exit is visible, `defer` is both needed and enough for
cleanup.

With exceptions, the main path of the code stays clean and the error handling
happens somewhere else. Error unions put a `try` on every fallible call. That
adds noise. In return, each `try` shows the reader a place where the function
might return early. A function also cannot fail in a way its signature does not
declare.
