# Build Modes

> Four modes, and what each one trades.

Zig has four build modes: `Debug`, `ReleaseSafe`, `ReleaseFast` and
`ReleaseSmall`. They differ in whether runtime safety checks stay in the
binary and whether the optimiser aims for speed or for size.

```zig
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // These snippets are built as .small. Master lowercased the mode tags:
    // .Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall are now
    // .debug/.safe/.fast/.small.
    try expect(builtin.optimize == .small);
}

test "safety checks follow the mode" {
    // True in .debug and .safe, false in .fast and .small.
    const safety_on = switch (builtin.optimize) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    try expect(!safety_on); // because we are in .small
}

test "safety can be forced back on for a scope" {
    // Useful for keeping bounds checks in one risky function of an
    // otherwise ReleaseFast build.
    @setRuntimeSafety(true);
    var index: usize = 1;
    _ = &index;
    const array = [_]u8{ 1, 2, 3 };
    try expect(array[index] == 2);
}

test "branch hints and unreachable" {
    // In safety builds `unreachable` panics. In ReleaseFast it is a promise
    // to the optimiser, and reaching it is illegal behaviour.
    const value: u8 = 2;
    switch (value) {
        1, 2, 3 => {},
        else => unreachable,
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`04-build-system.build-modes`)*

| Mode | Safety checks | Optimised | Size |
| --- | --- | --- | --- |
| `Debug` | yes | no | large |
| `ReleaseSafe` | yes | yes | medium |
| `ReleaseFast` | **no** | yes | medium |
| `ReleaseSmall` | **no** | yes | small |

Select with `-O`:

```bash
zig build-exe main.zig -OReleaseSafe
zig build -Doptimize=ReleaseSafe
```

## What each mode is actually for

- **`Debug`** is the default, and it is the one you develop in. Compilation is
  fast because there is almost no optimisation, every safety check is on, and
  `undefined` memory is filled with `0xaa`, so reading it uninitialised is easy
  to spot. Binaries are large and the code is slow. That is fine while you are
  editing.
- **`ReleaseSafe`** is the one to ship unless you have a reason not to. Full
  optimisation, checks retained.
- **`ReleaseFast`** removes the checks. Use it when a measurement shows the
  checks are the bottleneck. That happens less often than people expect.
- **`ReleaseSmall`** optimises for size instead of speed and also drops the
  checks. Embedded targets use it, and so does this site: a snippet here is
  about 70 KB, and the same snippet in `ReleaseSafe` is over a megabyte. The
  reader's browser has to download that before anything runs.

Those numbers are from this project, not an estimate. That is why only
five snippets here are built `.safe`: the ones whose job is to show a panic.

## `ReleaseSafe` deserves more use than it gets

In C and C++, a release build usually means an unchecked build. Zig keeps
the two choices separate: `ReleaseSafe` is optimised *and* keeps bounds checks,
overflow checks, and null-unwrap checks. For most software the cost is small and the
alternative is silent memory corruption.

Use `ReleaseFast` when you have measured that the checks matter. Do not use it
by default.

The two costs are very different. A check that stays in costs a compare and a
predictable branch. On modern hardware that is close to free, unless the code
is already memory-bound. A removed check costs nothing until the day an index
is wrong. Then it costs a corrupted heap and a bug you cannot reproduce. That
is a bad trade to make by default: a small cost you always pay, swapped for a
rare but very large one. For decades, C and C++ offered no other option.

## Where the checks are removed, the rules do not change

In `ReleaseFast` and `ReleaseSmall`, an out-of-bounds index is **illegal
behaviour**, the same category as C's undefined behaviour. The check only
reported that the rule was broken. Removing the check does not remove the
rule. Code that only
works because Debug caught the panic is already wrong.

If a program works in ReleaseFast, that does not show it is correct. It only
shows that nothing has caught the problem yet. The optimiser is allowed to
assume the rules are followed, and it uses that assumption to delete branches
you thought were there.

## Per-scope override

```zig
@setRuntimeSafety(true);
```

This keeps checks in one function of an otherwise unchecked build. It is
useful for a routine that parses untrusted input.

The reverse works too: `@setRuntimeSafety(false)` in one hot function of an
otherwise safe build. Prefer this approach. The unsafe code stays small and
easy to find and review. The other way makes the whole program unchecked to
speed up one loop.

## Knowing the mode at compile time

`@import("builtin").optimize` is a comptime value, so mode-specific code costs
nothing at runtime: the dead branch is not compiled in.

The tags are lowercase: `.debug`, `.safe`, `.fast`, `.small`. They used to be
`.Debug`, `.ReleaseSafe`, `.ReleaseFast` and `.ReleaseSmall`, so a comparison
copied from an older tutorial will not compile. The field was also renamed
from `mode` to `optimize`. `builtin.mode` still works for now, and the std
source marks it for removal after 0.18.0. On the command line both spellings
work: `-O ReleaseFast` and `-O fast` build the same thing.

So expensive assertions are practical. You can put a consistency check that
walks an entire data structure behind `if (builtin.optimize == .debug)`. In a
release build, that check is not in the binary at all. `std.debug.assert` is a
different tool: it lowers to `unreachable`, so it follows the safety checks
rather than the mode name, and it still fires in `ReleaseSafe`.
