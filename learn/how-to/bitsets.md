# Recipe: Set Operations on the Cheap

> A static bit set turns membership, intersection, and union into single instructions.

In Zig, `std.bit_set.Static(n)` stores a set of small integers as bits, so
union and intersection are bitwise operations and nothing allocates.
`std.bit_set.Static(24)` holds the hours of a day in a single `u24`.

## The problem

You need sets of small integers and set arithmetic over them: which hours two
calendars are both free, which of 64 seats are taken, which permissions two
roles share. A hash set works, but it allocates, chases pointers, and turns
"intersect two sets" into a loop with lookups.

When the set of possible members is small and known (hours 0 to 23, seats 0 to
63), a bit set does the same job as one integer and some bitwise operations.

## The plan

1. Pick the universe size at compile time: `std.bit_set.Static(24)` for hours
   of a day. At 24 bits the whole set is a single `u24`. This recipe uses
   no allocator anywhere.
2. Start from the `empty` constant and `set` the members.
3. Combine with `intersectWith` and `unionWith`, which return new sets, or
   their in-place cousins `setIntersection` and `setUnion`.
4. Ask questions with `isSet`, `count`, and `iterator`.

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

    // Two calendars, each a set of free hours in a day. 24 possible
    // members, so the whole set is stored as one u24. Every
    // operation below is a bitwise instruction or two.
    var ana: Hours = .empty;
    var raj: Hours = .empty;
    setHours(&ana, &.{ 9, 10, 11, 14, 15, 16 });
    setHours(&raj, &.{ 10, 11, 13, 15, 19 });

    try printHours(out, "ana", ana);
    try printHours(out, "raj", raj);

    // Overlap: the hours where a meeting can happen.
    try printHours(out, "both free", ana.intersectWith(raj));

    // Union answers the opposite question.
    try printHours(out, "either free", ana.unionWith(raj));

    // Single-membership checks are one bit test.
    try out.print("raj free at 14: {}\n", .{raj.isSet(14)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.bitsets`)*

## What changed in the API

Older material constructs these with `initEmpty()` and `initFull()`. Those
methods are gone on current master. The type now exposes `empty` and `full`
declaration constants instead, used with the `.empty` enum-literal-style
syntax:

```zig
var hours: std.bit_set.Static(24) = .empty;
```

The same pattern (`.empty` replacing `init` functions) applies across the
standard library's containers, so you learn it once and use it everywhere.

## Why this beats a hash set here

The intersection in the snippet compiles to an `and` instruction on a u24.
`count()` is a popcount. Iteration visits set bits directly rather than
scanning buckets. `Static` picks its representation from the size: a single
integer up to pointer width, an array of words beyond it. So a set for the
days of a year works the same way, just across several words.

The cost is that members must be small integers you can enumerate at compile
time. When keys are strings or unbounded, use [hash
maps](https://www.ziglang.in/learn/standard-library/hash-maps/) instead.

## Variations

- **Runtime-sized universes:** `std.bit_set.DynamicManaged` takes an allocator and a
  length chosen at runtime.
- **Difference and complement:** `differenceWith` answers "free for ana but
  not raj"; `complement()` flips the whole set.
- **First fit:** `findFirstSet()` returns the lowest member, useful for
  "earliest common hour" without iterating.
