# Random Numbers

> Seeded generators, passed explicitly.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a seeded generator is reproducible" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const first = random.int(u32);

    // Same seed, same sequence: that is what makes tests deterministic.
    var again = std.Random.DefaultPrng.init(42);
    try expect(again.random().int(u32) == first);
}

test "ranges" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..100) |_| {
        const die = random.intRangeAtMost(u8, 1, 6); // inclusive
        try expect(die >= 1 and die <= 6);

        const index = random.uintLessThan(usize, 10); // exclusive
        try expect(index < 10);
    }
}

test "floats and booleans" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    const f = random.float(f64); // [0, 1)
    try expect(f >= 0.0 and f < 1.0);

    _ = random.boolean();
}

test "shuffle a slice" {
    var prng = std.Random.DefaultPrng.init(1);
    var items = [_]u8{ 1, 2, 3, 4, 5 };
    prng.random().shuffle(u8, &items);

    var sum: u32 = 0;
    for (items) |i| sum += i;
    try expect(sum == 15); // same elements, different order
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.random-numbers`)*

There is no global `rand()`. You create a generator, seed it, and pass its
`Random` interface where it is needed: the same explicitness Zig applies to
allocators and I/O.

```zig
var prng = std.Random.DefaultPrng.init(seed);
const random = prng.random();
```

Two values, and the distinction matters. `prng` is the generator and owns the
state, so it has to be a `var` and has to outlive everything using it.
`random` is the interface: a pointer to that state plus a function pointer,
the same shape as `Allocator`. Functions take the interface, never the
generator. So a function that needs randomness can be handed a real generator
in production and a fixed-seed one in a test, without knowing the difference.

## Seeding

A fixed seed gives a reproducible sequence, which is what you want in tests.
For real unpredictability the entropy has to come from the operating system,
and on master that arrives through the `Io` interface like every other thing
that can block:

```zig
var source: std.Random.IoSource = .{ .io = io };
const random = source.interface();
```

`std.Random.DefaultCsprng` is the cryptographically secure generator, and is
what to use for tokens, keys, or anything an attacker should not predict.
`DefaultPrng` is fast, not secure. Do not use it for secrets.

If you have seen `std.crypto.random` in older code or tutorials, that is what
these replaced. There is no longer a global secure generator to reach for,
which is the same change that removed global stdout: the capability is passed
in rather than imported.

The difference between the two is not about quality of randomness in the
statistical sense. `DefaultPrng` passes statistical tests fine. It is that its
internal state can be reconstructed from a modest number of outputs, so an
attacker who sees a few session tokens can compute the next one. The secure
generator is built so that observing output tells you nothing about the state.

A fixed seed is a feature in tests. It is better than no randomness at all,
because a seeded generator explores inputs a hand-written test would not,
while still failing the same way every time. When a seeded test fails, print
the seed, and the failure is reproducible forever.

## Ranges

| Call | Range |
| --- | --- |
| `intRangeAtMost(T, lo, hi)` | `lo..=hi` inclusive |
| `intRangeLessThan(T, lo, hi)` | `lo..hi` |
| `uintLessThan(T, hi)` | `0..hi` |
| `float(T)` | `[0, 1)` |

These handle modulo bias properly. `random.int(u8) % 6` does not, and skews
toward low values.

`shuffle` permutes a slice in place.

The bias is small but it is real and it is easy to reason about. There are 256
values a `u8` can take and 6 outcomes wanted. 256 is not a multiple of 6, so
four of the outcomes get 43 chances and two get 42. A dice roll biased by 2%
is fine in a game and a problem in a simulation you are drawing conclusions
from. It also costs nothing to avoid: the standard library functions already
reject and redraw the values that would skew the result.

## Other things on the interface

`boolean()` for a coin flip, `weightedIndex` for picking from a distribution,
`enumValue(T)` for a random tag of an enum. `bytes(buf)` fills a slice, which
is how you generate an identifier or test payload in one call.

For picking a random element of a slice, `uintLessThan(usize, s.len)` is the
correct spelling, and it is worth writing that rather than `int(usize) %
s.len` for the reason above. It also fails loudly on an empty slice instead of
dividing by zero.
