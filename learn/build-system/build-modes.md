# Build Modes

> Four modes, and what each one trades.

```zig
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "the current mode is known at compile time" {
    // These snippets are built as .small. Master lowercased the mode tags:
    // .Debug/.ReleaseSafe/.ReleaseFast/.ReleaseSmall are now
    // .debug/.safe/.fast/.small.
    try expect(builtin.mode == .small);
}

test "safety checks follow the mode" {
    // True in .debug and .safe, false in .fast and .small.
    const safety_on = switch (builtin.mode) {
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
    // In safety builds `unreachable` panics; in ReleaseFast it is a promise
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

## `ReleaseSafe` deserves more use than it gets

The reflex from C and C++ is that release means unchecked. Zig makes that a
separate axis: `ReleaseSafe` is optimised *and* keeps bounds checks, overflow
checks, and null-unwrap checks. For most software the cost is small and the
alternative is silent memory corruption.

Reach for `ReleaseFast` when you have measured that the checks matter, not by
default.

## Where the checks are removed, the rules do not change

In `ReleaseFast` and `ReleaseSmall`, an out-of-bounds index is **illegal
behaviour**, the same category as C's undefined behaviour. The check was a
diagnostic for breaking the rule, not the definition of it. Code that only
works because Debug caught the panic is already wrong.

## Per-scope override

```zig
@setRuntimeSafety(true);
```

Keeps checks in one function of an otherwise unchecked build, useful for the
one routine parsing untrusted input.

## What each mode is actually for

- **`Debug`** is the default, and it is the one you develop in. Compilation is
  fast because there is almost no optimisation, every safety check is on, and
  `undefined` memory is filled with `0xaa` so reading it uninitialised is loud.
  Binaries are large and the code is slow, both of which are the correct trade
  while you are editing.
- **`ReleaseSafe`** is the one to ship unless you have a reason not to. Full
  optimisation, checks retained.
- **`ReleaseFast`** removes the checks. Reach for it when a measurement says the
  checks are the bottleneck, which is less often than instinct suggests.
- **`ReleaseSmall`** optimises for size instead of speed and also drops the
  checks. It is what an embedded target wants, and what this site uses: a
  snippet here is about 70 KB, and the same snippet in `ReleaseSafe` is over a
  megabyte, paid by the reader's browser before anything runs.

Those numbers are from this project, not an estimate. It is why the three
chapters here that deliberately trigger a panic are the only ones built `.safe`.

## `ReleaseSafe` deserves more use than it gets

The reflex from C and C++ is that release means unchecked. Zig makes that a
separate axis: `ReleaseSafe` is optimised *and* keeps bounds checks, overflow
checks, and null-unwrap checks. For most software the cost is small and the
alternative is silent memory corruption.

Reach for `ReleaseFast` when you have measured that the checks matter, not by
default.

The asymmetry is what makes the argument. A retained check costs a compare and a
predictable branch, which on modern hardware is close to free in code that is
not already memory-bound. A removed check costs nothing until the day the index
is wrong, and then it costs a corrupted heap and a bug that reproduces nowhere.
Trading a small certain cost for a rare catastrophic one is a bad trade to make
by default, and for decades it was the only option on offer.

## Where the checks are removed, the rules do not change

In `ReleaseFast` and `ReleaseSmall`, an out-of-bounds index is **illegal
behaviour**, the same category as C's undefined behaviour. The check was a
diagnostic for breaking the rule, not the definition of it. Code that only
works because Debug caught the panic is already wrong.

This is the sentence to keep. "It works in ReleaseFast" is not evidence that a
program is correct; it is evidence that nothing has caught it yet. The optimiser
is entitled to assume the rules are followed, and it uses that assumption to
delete branches you thought were there.

## Per-scope override

```zig
@setRuntimeSafety(true);
```

Keeps checks in one function of an otherwise unchecked build, useful for the
one routine parsing untrusted input.

The reverse works too: `@setRuntimeSafety(false)` in one hot function of an
otherwise safe build. That is the shape to prefer, because it makes the unsafe
region small, visible, and reviewable, rather than making the whole program
unchecked to speed up one loop.

## Knowing the mode at compile time

`@import("builtin").mode` is a comptime value, so mode-specific code costs
nothing at runtime: the dead branch is not compiled in.

Which makes expensive assertions practical. A consistency check that walks an
entire data structure can be written behind `if (builtin.mode == .Debug)` and it
is not merely skipped in release, it is not present. `std.debug.assert` works
the same way, and is the right tool for stating an invariant you want checked
while developing and gone when shipping.
