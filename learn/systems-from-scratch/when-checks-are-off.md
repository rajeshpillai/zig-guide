# When the Checks Are Off

> What undefined behaviour is, and what each build mode promises.

The last chapter ended on a difficult fact: the program that you ran said that
its safety checks were absent. The reason for this absence is the difference
between systems programming and all the levels above it.

A high-level language answers each question. If you read past the end of a
list, Python raises `IndexError`. Python does this always, on each machine, in
each configuration. This guarantee has a cost, and you pay the cost when you
need the guarantee and when you do not.

A systems language does not answer some questions, on purpose. This does not
mean "answered in a way that you cannot predict". It means **not answered**.
The specification says: if your program does this thing, the language makes no
promise about what occurs next. The name for this is **undefined behaviour**.

Undefined behaviour is not a special word for "crash" or for "garbage value".
It is neither of these.

Think of undefined behaviour as a promise that you made. When the language
leaves integer overflow undefined, the language tells the compiler to assume
that overflow never occurs. The compiler uses that assumption, because the
assumption makes the generated code fast. The compiler can delete a check that
you wrote, because your check can be true only in a situation that you
promised would not occur.

Thus undefined behaviour is worse than a wrong answer. A wrong answer stays in
one place. A broken promise can change code in a different place.

Zig uses this method: **the checks exist, and for each build you decide if you
pay for them.**

## The program

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Each program can see its build mode.
    try out.print("build mode: {t}\n", .{builtin.optimize});
    try out.print("safety checks present: {}\n\n", .{builtin.optimize.runtimeSafety()});

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // Four ways to say what must occur when 300 does not fit in a u8. None of
    // them change with the build mode, because none of them use a check that
    // a release build can remove.

    // 1. Wrap, on purpose.
    try out.print("a +% b            = {d}\n", .{a +% b});

    // 2. Refuse, with an error that the caller must handle.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add      = {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add      = {t}\n", .{err});
    }

    // 3. Give the answer and a flag, with no error to handle.
    const result = @addWithOverflow(a, b);
    try out.print("@addWithOverflow  = {d}, overflowed: {d}\n", .{ result[0], result[1] });

    // 4. Saturate at the limit.
    try out.print("a +| b            = {d}\n", .{a +| b});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.when-checks-are-off`)*

## What just happened

**The program read its own build mode.** Each Zig program can use
`builtin.optimize`. `builtin.optimize.runtimeSafety()` asks the direct
question: does this build have the checks? Print these two values as a habit.
Almost all bugs of the type "why is it different on the server" has this
cause.

The four modes, and the promise of each mode:

- **Debug**: all the safety checks are present, and there is no optimisation.
  Debug is the default for `zig run` and `zig build`. Thus you use Debug for
  all of your daily work. Overflow, out-of-bounds access, invalid casts and
  the other checked errors stop the program with a message and a line number.
- **ReleaseSafe**: the compiler optimises the build, and the safety checks
  stay. Use
  this mode for most server software. The checks have a cost, but the
  cost is small. A program that stops with a clear message is better than a
  program that continues with corrupt state.
- **ReleaseFast**: the compiler optimises the build and removes the checks.
  You promise that none of the checked situations occur.
- **ReleaseSmall**: the compiler optimises the build for size and removes
  the checks. The promise is the same.

The snippets on this site are ReleaseSmall builds, because each reader
downloads them. For that reason, the output above says `small` and `false`.

**The four operators gave the same result in each mode.** `+%`,
`std.math.add`, `@addWithOverflow` and `+|` behave the same in all four
modes. Each of them states in the source what must occur when the value does
not fit. They do not use a check that a release build can remove. When
overflow is important, write in the source what you want. Then the build mode
does not change the answer.

## The one that depends on the build

The program below adds the same two values as the four lines above, with a
plain `+`. It is the one snippet on this page that is a ReleaseSafe build and
not a ReleaseSmall build. Thus the check is still in it. Press **Run**.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // 300 does not fit in a u8. In this build, the check runs and the program
    // stops here. ReleaseFast and ReleaseSmall have no check, and the value is
    // undefined. The value does not always wrap.
    const sum = a + b;

    std.debug.print("sum: {d}\n", .{sum});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.the-one-that-depends`)*

```
panic: integer overflow
```

Compare this result with the four operators above. Each of those operators
answered the question in the source. Thus each operator behaves the same in
all four modes. The plain `+` asked the build mode for the answer. Thus the
answer depends on the build:

| Build | `a + b` where the sum does not fit |
| --- | --- |
| Debug | stops, with the message above |
| ReleaseSafe | stops, with the message above |
| ReleaseFast | undefined |
| ReleaseSmall | undefined |

The last two rows do **not** say "wraps". The value can wrap on your machine
today. Code that depends on that wrap is exactly the broken promise at the top
of this page. If you want the value to wrap, use `+%`. The `+%` operator costs
nothing.

This page shows you the panic, but it cannot show you the other half, and
there is a reason.

In a safety build, the behaviour is defined. Thus the build for this site runs
this program on each change, and the program must stop with that exact
message. In a release build, no answer is defined. Thus no correct result
exists to compare with.

A guide could print the output of its compiler on that day, and call that
output the result. That guide would teach you to trust the thing that this
chapter warns you about.

## Check yourself

ReleaseSafe keeps the checks, and the compiler optimises it. Then why does a
programmer ship ReleaseFast?

The checks do not always cost little in the place where speed is important. A
bounds check inside a loop that runs a billion times per frame has a cost that
you can measure. In some programs, that speed is the most important thing.

The decision is for each program, and sometimes for each function. For this
reason, Zig lets you turn safety off for one block with
`@setRuntimeSafety(false)`. You do not have to select all or nothing for the
full binary. Start in ReleaseSafe, and make a change only where you measured
the cost.

## If you know C

Undefined behaviour is the same idea in C, and C has much more of it:

- signed overflow
- a read of an uninitialised variable
- a read through a null pointer
- most pointer arithmetic that goes outside an object
- strict-aliasing violations
- about two hundred more

By default, C checks almost none of these. For this reason, sanitiser tools
exist, and `-fsanitize=undefined` finds problems in code that worked for ten
years.

Zig is different in three places:

- The default build mode has the checks on. Thus you see the mistake the
  first time that you run the code. You do not have to know about a special
  flag and add it later.
- Where C leaves a common operation undefined, Zig usually gives a different
  syntax for each intent. The four operators above are an example.
- You must write an uninitialised variable as `= undefined`. Thus you can
  search for each one with grep.

[Runtime Safety](https://www.ziglang.in/learn/language-basics/runtime-safety/) gives the list for
Zig: what Zig checks, and what each check finds. [Integer
Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) gives the integer rules in
detail.

Next: [Strings Are Bytes](https://www.ziglang.in/learn/systems-from-scratch/strings-are-bytes/). In
that chapter, the bytes from chapter one become text.
