# Random Numbers

> Seeded generators that you give to your code as arguments.

Zig has two random number generators:

- `std.Random.DefaultPrng` is fast, and you can give it a seed. Use it for tests and simulations.
- `std.Random.DefaultCsprng` is the secure generator. Use it for tokens and keys.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "a seeded generator is reproducible" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const first = random.int(u32);

    // The same seed gives the same sequence. Thus the tests are deterministic.
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

Zig has no global `rand()`. You create a generator, give it a seed, and give its `Random` interface to the code that needs it. Code gets allocators and I/O in the same way.

```zig
var prng = std.Random.DefaultPrng.init(seed);
const random = prng.random();
```

The two values in this code do different work. `prng` is the generator, and it owns the state. Thus `prng` must be a `var`, and it must exist longer than all the code that uses it.

`random` is the interface. It is a pointer to that state and a function pointer, the same shape as `Allocator`. Functions take the interface, never the generator. Thus you can give a real generator to a function in production, and a generator with a fixed seed in a test. The function does not know the difference.

## Seeds

A fixed seed gives a sequence that is the same each time. Tests need that. For values that nobody can predict, the entropy must come from the operating system. On master, the entropy comes through the `Io` interface, as all other operations that can block do:

```zig
var source: std.Random.IoSource = .{ .io = io };
const random = source.interface();
```

`std.Random.DefaultCsprng` is the cryptographically secure generator. Use it for tokens, keys, and all other values that an attacker must not predict. `DefaultPrng` is fast, but it is not secure. Do not use it for secrets.

Older code and tutorials use `std.crypto.random`. These generators replaced it. Zig no longer has a global secure generator. The same change removed the global stdout. Code now gets the capability as an argument, and does not import it.

The difference between the two generators is not statistical quality. `DefaultPrng` passes statistical tests. The problem is that a small number of outputs is sufficient to calculate its internal state again. Thus an attacker who sees a few session tokens can calculate the next token. The design of the secure generator makes sure that its output tells you nothing about the state.

In tests, a fixed seed is a useful feature. A seeded generator is better than no random values at all. It tries inputs that a hand-written test does not try, and it still fails in the same way each time. When a seeded test fails, print the seed. Then you can make the failure occur again at any time.

## Ranges

| Call | Range |
| --- | --- |
| `intRangeAtMost(T, lo, hi)` | `lo..=hi` inclusive |
| `intRangeLessThan(T, lo, hi)` | `lo..hi` |
| `uintLessThan(T, hi)` | `0..hi` |
| `float(T)` | `[0, 1)` |

These functions prevent modulo bias. `random.int(u8) % 6` does not prevent it, and its results are more frequently low values.

`shuffle` changes the order of a slice in place.

The bias is small, but it is real, and you can calculate it. A `u8` has 256 possible values, and the code wants 6 outcomes. 256 is not a multiple of 6. Thus four of the outcomes get 43 chances, and two outcomes get 42.

A dice roll with a bias of 2% is acceptable in a game. It is a problem in a simulation that you use to make conclusions. You do no extra work to prevent the bias. The standard library functions already reject the values that cause the bias, and draw a new value.

## Other functions on the interface

- `boolean()` gives the result of a coin flip.
- `weightedIndex` selects an index from a distribution.
- `enumValue(T)` gives a random tag of an enum.
- `bytes(buf)` fills a slice. Use it to make an identifier or a test payload in one call.

To select a random element of a slice, the correct call is `uintLessThan(usize, s.len)`. Use it and not `int(usize) % s.len`, for the reason above. Also, on an empty slice, `uintLessThan` fails, and the failure is easy to see. It does not divide by zero.
