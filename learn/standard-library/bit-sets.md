# Bit Sets and Enum Collections

> A set of small integers in a word, and containers with an enum as the key.

`std.bit_set.Static(N)` stores a set of the integers `0..N` as bits, with no allocator. `EnumSet`, `EnumArray` and `EnumMap` change an enum into one of three containers:

- a set
- a table with a value for each tag
- a map with values for some tags

```zig
const std = @import("std");
const expect = std.testing.expect;

test "static bit set" {
    // 64 bits, stored inline. An allocator is not necessary.
    var seen: std.bit_set.Static(64) = .empty;

    seen.set(3);
    seen.set(40);
    try expect(seen.isSet(3));
    try expect(!seen.isSet(4));
    try expect(seen.count() == 2);

    // Gives the indices of the set bits in ascending order.
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
    // Each key exists. The initialization must give a value for each key.
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

Older code calls this type `std.StaticBitSet`. The type stores the bits inline. When `N` is small, the type is one integer. When `N` is larger, the type is an array of words. The API is the same for the two layouts: `set`, `unset`, `isSet`, `count`.

If you know the size only at run time, use `std.bit_set.DynamicManaged`. This type takes an allocator.

Union and intersection are single instructions on the backing words. Thus `unionWith` and `intersectWith` are cheap. With `findFirstSet` and the ascending `iterator`, you can find the members without a scan of each index.

## Containers with an enum as the key

Three types change an enum into a container. The difference between them is the result for a key that you did not set:

| Type | Holds | A key that you did not set |
| --- | --- | --- |
| `EnumSet(E)` | membership only | not present |
| `EnumArray(E, V)` | a `V` for each tag | not possible: init sets all keys |
| `EnumMap(E, V)` | a `V` for some tags | `get` returns null |

An `EnumArray` always has a value for each tag. Thus its `get` returns `V`, not `?V`. The compiler makes you supply each field at initialization. Use `EnumArray` for lookup tables that must cover the full enum, for example a duration for each state of a traffic light.

`EnumMap` is the partial version. Use it when the absence of a key has a meaning. The three types use the same bit-set machinery. Thus they are compact, and they do not allocate.

The coverage of each tag is the main reason to use `EnumArray`. When you add a tag to the enum, each `EnumArray` initialiser becomes a compile error. The error gives the name of the tag that has no value. An exhaustive `switch` gives the same guarantee, for the same reason. A `HashMap` with the enum as the key compiles, and it returns null at runtime.

## What these types replace

These types replace a `[]bool`, or an array of booleans. The bit set uses eight times less memory. Also, it does a set operation in one instruction, not in a loop.

For example, take a record of which of 256 opcodes have an implementation. As a bit set, the record costs 32 bytes. As an array of `bool`, it costs 256 bytes. At that size, the difference is not important.

At sixty-four thousand flags, the bit set is 8 KB, and it stays in L1 on most machines. The array of `bool` is 64 KB, and it does not stay in L1. A test for "is any of these set" changes from a scan to a small number of `or` operations.

These types also replace a `flags: u32` that you write by hand, with named constants and manual `&` and `|`. That method works, and C uses it. But the bit positions are only in comments. Nothing stops a test of the wrong bit. To print the set, you must write a formatter. `EnumSet` gives the same layout, with names that the compiler checks.

## Iterate over a set

`iterator()` gives the indices of the set bits, in ascending order. It does not test each index. It skips a word of zeroes in one step. Take a sparse set over a large range. The time of the loop is proportional to the number of members, not to the size of the range.

`findFirstSet` returns the lowest member. A free-list allocator needs this operation. The bit set is the map of the available blocks, and the first set bit is the next block to give out. `toggleAll`, `unionWith`, `intersectWith` and `differenceWith` complete the set algebra.

## Select a size

`std.bit_set.Static(N)` stores its bits inline. Thus you can copy the type, and it has no pointers inside. It can be a struct field, and a function can return it by value. For these reasons, it is the default choice.

`DynamicManaged` is for an `N` that the program decides at run time. It takes an allocator, and it needs a `deinit`. Before you use it, make sure that you really have no upper limit. Usually, a static set with a large maximum size is simpler and smaller than a heap allocation and a pointer.
