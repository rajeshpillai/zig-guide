# Runtime Safety

> Checked illegal behaviour, and where the checks go.

Zig inserts runtime checks for a class of mistakes that C leaves undefined:
out-of-bounds indexing, integer overflow, invalid casts, unwrapping a null
optional, and more. When a check fails the program panics with a clear message
instead of quietly reading whatever came next in memory.

Press **Run**. It reads index 5 of a three-element array:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    // Zig inserts checks for out-of-bounds access, integer overflow, invalid
    // casts, and more. In a safety-enabled build this panics with
    // "index out of bounds" rather than reading whatever memory follows.
    const array = [_]u8{ 1, 2, 3 };
    var index: usize = 5;
    _ = &index; // defeat comptime evaluation
    const value = array[index];
    std.debug.print("never printed: {d}\n", .{value});
}

// Deliberately panics, which is the point: CI runs it and requires it to stop
// with exactly the message this chapter quotes.
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.runtime-safety`)*

```
panic: index out of bounds: index 5, len 3
```

The message names the index it was given and the length it was allowed. The
`std.debug.print` on the next line never runs, and no memory outside the array
was ever read. In C the same three lines produce a number, and which number
depends on what happened to be sitting after the array.

## Integer overflow

The same treatment applies to arithmetic. This adds 1 to a `u8` holding 255:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var x: u8 = 255;
    _ = &x; // defeat comptime evaluation

    // 256 does not fit in a u8. `+=` is the checked add: in this build the
    // check runs and the program stops here. In ReleaseFast or ReleaseSmall
    // there is no check, and the value is not defined. Not "wraps". Undefined.
    x += 1;

    std.debug.print("never printed: {d}\n", .{x});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.safety-overflow`)*

```
panic: integer overflow
```

C would give you 0 here, quietly, and the bug would surface somewhere else
entirely. Zig stops at the line that was wrong.

The important part is that `+` is not refusing to wrap. It is refusing to
guess. Wrapping is a perfectly reasonable thing to want in a hash function or
a checksum, so Zig gives it a different operator and makes the choice visible
at the call site:

```zig
const std = @import("std");
const expect = std.testing.expect;

test "+% wraps, and says so at the call site" {
    var x: u8 = 255;
    _ = &x;
    // `x + 1` is the checked add and stops the program. `+%` is a different
    // operator with a defined answer, in every build mode.
    try expect(x +% 1 == 0);
}

test "+| saturates at the limit instead" {
    var x: u8 = 250;
    _ = &x;
    try expect(x +| 10 == 255);
}

test "@addWithOverflow reports rather than stops" {
    var x: u8 = 255;
    _ = &x;
    // A tuple: the wrapped value, and a u1 that is 1 when it overflowed.
    const result = @addWithOverflow(x, 1);
    try expect(result[0] == 0);
    try expect(result[1] == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.safety-wrapping`)*

`+%` wraps, `+|` saturates at the type's limit, and `@addWithOverflow` hands
back both the wrapped value and a flag saying whether it overflowed. All three
are defined in every build mode, because you asked for them. Plain `+` is the
one that means "this should not overflow, tell me if it does".

## Unwrapping a null optional

`.?` on an optional is an assertion, not a conversion. It says the value is
not null. When that is false, the check fires:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var maybe: ?u32 = null;
    _ = &maybe; // defeat comptime evaluation

    // `.?` is a claim: "this is not null, give me the payload". The claim is
    // false here, so the check stops the program rather than handing back
    // whatever bits happened to be in the payload.
    const value = maybe.?;

    std.debug.print("never printed: {d}\n", .{value});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.safety-null-unwrap`)*

```
panic: attempt to use null value
```

This is the check you will meet most often, because `.?` is easy to reach for
when the alternative is handling a case you are confident cannot happen. It is
also the one with the best alternatives: `orelse` supplies a default, and
`if (maybe) |value|` gives you the payload only on the branch where it exists.
Both are covered in [optionals](https://www.ziglang.in/learn/language-basics/optionals/).

## Safety depends on the build mode

| Mode | Safety checks | Optimised |
| --- | --- | --- |
| `Debug` | yes | no |
| `ReleaseSafe` | yes | yes |
| `ReleaseFast` | **no** | yes |
| `ReleaseSmall` | **no** | yes |

This is the decision C never gives you explicitly. `ReleaseSafe` keeps the
checks and is a genuinely reasonable default for production; `ReleaseFast`
trades them for speed.

Where a check is removed, the situation it was catching becomes **illegal
behaviour**: the same category as C's undefined behaviour, with the same
consequences.

<aside>

**Runtime safety does not make incorrect code correct.** It makes some classes
of incorrect code fail loudly instead of continuing with corrupted state.

Every panic on this page is a program that was already wrong before the check
fired. Reading index 5 of a three-element array is a bug in `Debug` and a bug
in `ReleaseFast`; the difference is only whether you find out. The checks are
not the definition of correctness, they are a diagnostic for violating it, and
a `ReleaseFast` build of a program that panics under `ReleaseSafe` has not
fixed anything. It has stopped telling you.

</aside>

You can override the setting for a scope with `@setRuntimeSafety(true)`, which
is useful for keeping bounds checks in one hot-but-hairy function of an
otherwise `ReleaseFast` build.

<aside>

Snippets on this site build as `ReleaseSmall`, where the checks are off. Three
on this page are the exception: the out-of-bounds read, the overflow, and the
null unwrap are built `ReleaseSafe` on purpose, because a chapter about a check
firing should be able to show one fire. Our build runs all three on every
change and requires each to stop with exactly the message quoted above it, so
those messages are checked nightly rather than remembered. Each costs about
1.1 MB, against the 79 KB a snippet here usually weighs. That is the price of
the checks and the machinery that describes them, and it downloads only when
you press Run on that particular snippet.

The wrapping snippet is an ordinary `ReleaseSmall` build, because `+%`, `+|`
and `@addWithOverflow` are defined in every mode and need no check to
demonstrate.

</aside>
