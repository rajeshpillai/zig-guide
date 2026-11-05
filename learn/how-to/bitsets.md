# Recipe: Set Operations on the Cheap

> A static bit set does membership, intersection and union with one instruction each.

In Zig, `std.bit_set.Static(n)` keeps a set of small integers as bits. Thus union and intersection are bitwise operations, and no code allocates memory. `std.bit_set.Static(24)` keeps the hours of a day in one `u24`.

## The problem

You need sets of small integers, and set arithmetic on these sets. Some examples:

- the hours when two calendars are both free
- the seats, of 64, that people use
- the permissions that two roles share

A hash set can do this work. But a hash set allocates memory and follows pointers. Also, with a hash set, the intersection of two sets is a loop with lookups.

Sometimes the possible members are few and known, for example hours 0 to 23 or seats 0 to 63. Then a bit set does the same work with one integer and some bitwise operations.

## The plan

1. Select the size of the universe at compile time: `std.bit_set.Static(24)` for the hours of a day. At 24 bits, the full set is one `u24`. This recipe does not use an allocator.
2. Start from the `empty` constant, and `set` the members.
3. Combine sets with `intersectWith` and `unionWith`, which return new sets. The functions `setIntersection` and `setUnion` do the same operations in place.
4. Get information with `isSet`, `count` and `iterator`.

```zig
const std = @import("std");

const Hours = std.bit_set.Static(24);

fn setHours(set: *Hours, hours: []const u5) void {
    for (hours) |h| set.set(h);
}

fn printHours(out: *std.Io.Writer, label: []const u8, set: Hours) !void {
    try out.print("{s} ({d} free):", .{ label, set.count() });
    var it = set.iterator(.{});
    while (it.next()) |h| try out.print(" {d}", .{h});
    try out.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Two calendars. Each calendar is a set of free hours in a day. A set
    // has 24 possible members, thus one u24 keeps the full set. Each
    // operation below is one or two bitwise instructions.
    var ana: Hours = .empty;
    var raj: Hours = .empty;
    setHours(&ana, &.{ 9, 10, 11, 14, 15, 16 });
    setHours(&raj, &.{ 10, 11, 13, 15, 19 });

    try printHours(out, "ana", ana);
    try printHours(out, "raj", raj);

    // Intersection: the hours when a meeting can occur.
    try printHours(out, "both free", ana.intersectWith(raj));

    // Union gives the hours when one or both people are free.
    try printHours(out, "either free", ana.unionWith(raj));

    // A check for one member is one bit test.
    try out.print("raj free at 14: {}\n", .{raj.isSet(14)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.bitsets`)*

## What changed in the API

Older material makes these sets with `initEmpty()` and `initFull()`. Current master does not have those methods. Now the type has the declaration constants `empty` and `full`. Use them with the `.empty` syntax, which looks like an enum literal:

```zig
var hours: std.bit_set.Static(24) = .empty;
```

The containers of the standard library use the same pattern: `.empty` replaces the `init` functions. Thus you learn the pattern one time and use it everywhere.

## Why a bit set is better than a hash set here

In the snippet, the intersection compiles to one `and` instruction on a u24. `count()` is a popcount. The iterator goes directly to the bits that are set, and it does not examine buckets.

`Static` selects its representation from the size. Up to the pointer width, it uses one integer. For a larger size, it uses an array of words. Thus a set for the days of a year works in the same way, but on several words.

There is a cost. The members must be small integers that you can count at compile time. When the keys are strings or have no limit, use [hash maps](https://www.ziglang.in/learn/standard-library/hash-maps/).

## Variations

- **A universe with a size from runtime:** `std.bit_set.DynamicManaged` takes an allocator and a length that the program selects at runtime.
- **Difference and complement:** `differenceWith` gives the hours when ana is free and raj is not free. `complement()` changes each bit of the set to its opposite value.
- **First fit:** `findFirstSet()` returns the lowest member. Use it to get the earliest common hour without an iterator.
