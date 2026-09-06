# When the Checks Are Off

> What undefined behaviour actually is, and what each build mode promises.

The last chapter ended on an awkward admission: the program you ran said its
safety checks were absent. This chapter is why, and it is the idea that
separates systems programming from everything above it.

A high-level language answers every question. Read past the end of a list and
Python raises `IndexError`. Always, on every machine, in every configuration.
The answer costs something to guarantee, and you pay it whether you needed it
or not.

Down here some questions are deliberately left unanswered. Not "answered
unpredictably": **unanswered**. The specification says that if your program
does this thing, the language makes no promise about what happens next. That
is
**undefined behaviour**, and it is easy to misread as a fancy way of saying
"crash" or "garbage value". It is neither.

The right way to read it is as a promise you made. When the language leaves
integer overflow undefined, it is telling the compiler: assume it never
happens. The compiler then uses that assumption, because that is what makes
the generated code fast. It might delete a check you wrote, because your check
could only be true in a situation you promised would not arise. This is why
undefined behaviour is worse than a wrong answer. A wrong answer is local. A
broken promise can change code somewhere else.

Zig's position is the interesting one: **the checks exist, and you choose per
build whether to pay for them.**

## The program

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Every program can see how it was built.
    try out.print("build mode: {t}\n", .{builtin.mode});
    try out.print("safety checks present: {}\n\n", .{builtin.mode.runtimeSafety()});

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // Three ways of saying what should happen when 300 does not fit in a u8.
    // None of them change with the build mode, because none of them are
    // relying on a check that a release build is allowed to remove.

    // 1. Wrap, deliberately.
    try out.print("a +% b            = {d}\n", .{a +% b});

    // 2. Refuse, as an error the caller has to handle.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add      = {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add      = {t}\n", .{err});
    }

    // 3. Answer and report, with no error handling at all.
    const result = @addWithOverflow(a, b);
    try out.print("@addWithOverflow  = {d}, overflowed: {d}\n", .{ result[0], result[1] });

    // 4. Saturate at the limit.
    try out.print("a +| b            = {d}\n", .{a +| b});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.when-checks-are-off`)*

## What just happened

**The program read its own build mode.** `builtin.mode` is available to any Zig
program, and `builtin.mode.runtimeSafety()` is the direct question: are the
checks in this build. Printing them is a habit worth having, because almost
every "why does it behave differently on the server" story ends here.

The four modes, and what each is promising:

- **Debug**: every safety check present, no optimisation. This is the default
  for `zig run` and `zig build`, so it is what you get the entire time you are
  working. Overflow, out-of-bounds, invalid casts and the rest all stop the
  program with a message and a line number.
- **ReleaseSafe**: optimised, and the safety checks stay. This is the mode most
  server software should ship in. The checks are not free, but they are cheap,
  and a program that stops with a clear message beats one that continues with
  corrupt state.
- **ReleaseFast**: optimised, checks removed. You are promising that none of
  the checked situations occur.
- **ReleaseSmall**: optimised for size, checks removed. Same promise.

The snippets on this site are built ReleaseSmall, because they are downloaded
by every reader, which is why the output above says `small` and `false`.

**The four operators did not care.** `+%`, `std.math.add`, `@addWithOverflow`
and `+|` behave identically in all four modes, because each of them states in
the source what should happen when the value does not fit. They are not
relying on a check that a release build is entitled to remove. When it
matters, say what you mean and the build mode stops being part of the answer.

## The one that does depend on the build

This is the same program as the last four lines above, using plain `+`. It is
the one snippet on this page built ReleaseSafe rather than ReleaseSmall, so
the check is still in it. Press **Run**.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // 300 does not fit in a u8. In this build the check runs and stops here.
    // In ReleaseFast or ReleaseSmall there is no check, and the value you
    // would get is not defined. Not "wraps". Undefined.
    const sum = a + b;

    std.debug.print("sum: {d}\n", .{sum});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.the-one-that-depends`)*

```
panic: integer overflow
```

Now read that back against the four operators that did not care. Each of them
answered the question in the source, so each behaves the same in all four
modes. This one asked the build mode to answer it, and got a different answer
depending on which build you are in:

| Build | `a + b` where the sum does not fit |
| --- | --- |
| Debug | stops, with the message above |
| ReleaseSafe | stops, with the message above |
| ReleaseFast | undefined |
| ReleaseSmall | undefined |

Note what the last two rows do **not** say. Not "wraps". It might wrap on your
machine today, and writing code that depends on that is exactly the broken
promise described at the top of this page. `+%` is right there and costs
nothing.

There is a reason this page can show you the panic and cannot show you the
other half. In a safety build the behaviour is defined, so our build runs this
program on every change and requires it to stop with that exact message. In a
release build there is no defined answer, so there would be nothing correct to
check it against. A guide could print whatever its compiler happened to
produce that day and call it the result. That would be teaching you to rely on
the very thing this chapter warns you about.

## Check yourself

If ReleaseSafe keeps the checks and is optimised, why would anyone ship
ReleaseFast?

Because the checks are not always cheap in the place that matters. A bounds
check inside a loop running a billion times per frame is measurable, and there
are programs where that is the whole point. The judgement is per program, and
sometimes per function. That is why Zig lets you turn safety off for a single
block with `@setRuntimeSafety(false)`, instead of making it all or nothing for
the whole binary. Start in ReleaseSafe and move only where you have measured.

## If you have written C

Undefined behaviour is the same idea, and C has far more of it. Signed
overflow. Reading an uninitialised variable. Following a null pointer. Most
pointer arithmetic that leaves an object. Strict-aliasing violations. And
about two hundred more. Almost none of it is checked by default, which is why
the sanitiser tooling exists and why `-fsanitize=undefined` finds things in
code that has worked for a decade.

Zig differs in three places. The default build mode has the checks on. So you
meet the mistake the first time you run the code, not later, after adding a
flag you had to know about. Where C leaves a common operation undefined, Zig
usually provides a spelling for each intent instead, which is what the four
operators above are. And an uninitialised variable has to be written `=
undefined`, so reading one is a thing you can grep for.

The Zig-specific list, what is checked and what each check catches, is in
[Runtime Safety](https://www.ziglang.in/learn/language-basics/runtime-safety/), and the integer
rules in detail are in [Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/).

Next: [Strings Are Bytes](https://www.ziglang.in/learn/systems-from-scratch/strings-are-bytes/),
where the bytes from chapter one turn into text.
