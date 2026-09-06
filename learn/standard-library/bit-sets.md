# Bit Sets and Enum Collections

> A set of small integers in a word, and containers keyed by enums.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "static bit set" {
    // 64 bits, stored inline. No allocator anywhere.
    var seen: std.bit_set.Static(64) = .empty;

    seen.set(3);
    seen.set(40);
    try expect(seen.isSet(3));
    try expect(!seen.isSet(4));
    try expect(seen.count() == 2);

    // Iterates set bit indices in ascending order.
    var it = seen.iterator(.{});
    try expect(it.next().? == 3);
    try expect(it.next().? == 40);
    try expect(it.next() == null);
}

test "set algebra" {
    var a: std.bit_set.Static(16) = .empty;
    var b: std.bit_set.Static(16) = .empty;
    a.set(1);
    a.set(2);
    b.set(2);
    b.set(3);

    const both = a.intersectWith(b);
    try expect(both.count() == 1 and both.isSet(2));

    const either = a.unionWith(b);
    try expect(either.count() == 3);
}

test "ranges" {
    var mask: std.bit_set.Static(32) = .empty;
    mask.setRangeValue(.{ .start = 8, .end = 16 }, true);
    try expect(mask.count() == 8);
    try expect(mask.findFirstSet().? == 8);
}

const Perm = enum { read, write, execute };

test "EnumSet: a bit set keyed by an enum" {
    var perms = std.EnumSet(Perm).initMany(&.{ .read, .write });

    try expect(perms.contains(.read));
    try expect(!perms.contains(.execute));

    perms.insert(.execute);
    perms.remove(.write);
    try expect(perms.count() == 2);
}

const Light = enum { red, yellow, green };

test "EnumArray: one value per enum tag, no optionals" {
    // Every key exists; initialization must cover all of them.
    var durations = std.EnumArray(Light, u32).init(.{
        .red = 30,
        .yellow = 5,
        .green = 25,
    });

    try expect(durations.get(.red) == 30);
    durations.set(.yellow, 4);
    try expect(durations.get(.yellow) == 4);
}

test "EnumMap: some keys may be absent" {
    var overrides = std.EnumMap(Light, u32).init(.{ .red = 45 });

    try expect(overrides.get(.red).? == 45);
    try expect(overrides.get(.green) == null);

    overrides.put(.green, 20);
    try expect(overrides.count() == 2);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.bit-sets`)*

## A set that fits in registers

`std.bit_set.Static(N)` (`std.StaticBitSet` in older code) stores membership
for integers `0..N` as bits, inline, no allocator. Inside, it is a single
integer when `N` is small enough, and an array of words otherwise. The API is
the same either way: `set`, `unset`, `isSet`, `count`. When the size is only
known at run time, reach for `std.bit_set.DynamicManaged`, which does take an
allocator.

Union and intersection are single instructions on the backing words, so
`unionWith` and `intersectWith` are cheap. `findFirstSet` and the ascending
`iterator` let you walk membership without scanning every index.

## Containers keyed by an enum

Three types turn an enum into a container, and the difference is what happens
to keys you did not set:

| Type | Holds | Missing key |
| --- | --- | --- |
| `EnumSet(E)` | membership only | not present |
| `EnumArray(E, V)` | a `V` for every tag | cannot happen: all set at init |
| `EnumMap(E, V)` | a `V` for some tags | `get` returns null |

`EnumArray` is total by construction, so its `get` returns `V`, not `?V`, and
the compiler forces you to supply every field at initialization. Use it for
lookup tables that must cover the whole enum, like a duration per traffic
light state. `EnumMap` is the partial version for when absence is meaningful.
All three are backed by the same bit-set machinery, so they are compact and
allocation-free.

The totality of `EnumArray` is the property worth reaching for. Adding a tag
to the enum turns every `EnumArray` initialiser into a compile error naming
the missing case. That is the same guarantee an exhaustive `switch` gives, and
for the same reason. A `HashMap` keyed by the enum would have compiled and
returned null at runtime.

## What this replaces

The pattern these types replace is a `[]bool`, or an array of booleans. The
difference is a factor of eight in memory, plus the ability to do set
operations in one instruction instead of a loop.

Concretely: tracking which of 256 opcodes are implemented costs 32 bytes as a
bit set and 256 bytes as an array of `bool`. At that size neither matters. At
sixty-four thousand flags, one fits in a cache line's worth of words and the
other does not fit in L1 at all. "Is any of these set" goes from a scan to a
handful of `or`s.

The other thing it replaces is the hand-rolled `flags: u32` with named
constants and manual `&` and `|`. That works and is what C does, but the bit
positions live in comments, nothing stops you testing the wrong one, and
printing the set means writing a formatter. `EnumSet` gives the same layout
with names the compiler checks.

## Iterating

`iterator()` yields the indices that are set, in ascending order, skipping
runs of zeroes a word at a time rather than testing every index. For a sparse
set over a large range that is the difference between the loop being
proportional to the number of members and proportional to the size of the
universe.

`findFirstSet` returns the lowest member. That is what a free-list allocator
wants: the bit set is the map of what is available, and the first set bit is
the block to hand out. `toggleAll`, `unionWith`, `intersectWith` and
`differenceWith` complete the set algebra.

## Sizing

`std.bit_set.Static(N)` picks its own representation: a single integer when
`N` fits in one, an array of words when it does not. That means the type is
copyable, has no pointers inside, and can live in a struct field or be
returned by value, which is why it is the default choice.

`DynamicManaged` is for when `N` is decided at run time, and it takes an
allocator and needs a `deinit`. Before using it, ask whether an upper bound is
genuinely unknown. A static set sized to a generous maximum is usually both
simpler and smaller than a heap allocation and a pointer.
