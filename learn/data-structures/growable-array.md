# A Growable Array

> A length, a capacity, and one rule about what happens when they meet.

An array whose length changes. The standard library calls it `ArrayList`, and
it is the container most programs reach for and never move away from.

Building one takes three fields and a single rule about what happens when the
values fill the space they were given. Everything expensive about the
structure lives in that rule.

```zig
const std = @import("std");

/// Concrete `i32` on purpose. Making it work for any type is the next
/// chapter, and it is a smaller change than it looks.
const Array = struct {
    /// The whole allocation. `buffer.len` is the capacity, which is how many
    /// items would fit, not how many are there.
    buffer: []i32 = &.{},
    /// How many of those slots hold a value. Always <= buffer.len.
    len: usize = 0,
    allocator: std.mem.Allocator,

    /// Counters so the growth policy can be watched rather than described.
    growths: usize = 0,
    carried: usize = 0,

    fn init(allocator: std.mem.Allocator) Array {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Array) void {
        self.allocator.free(self.buffer);
        self.buffer = &.{};
        self.len = 0;
    }

    /// The live values. A slice into the buffer, valid until the next growth,
    /// which is the whole hazard of this structure in one sentence.
    fn items(self: *const Array) []i32 {
        return self.buffer[0..self.len];
    }

    /// Make room for at least `wanted` slots.
    ///
    /// Written as allocate, copy, free rather than as `realloc`, because that
    /// is what growing an array is and the copy is the cost being counted.
    /// `Allocator.realloc` does exactly this and may skip the copy when the
    /// allocation can be extended where it already sits.
    fn ensureCapacity(self: *Array, wanted: usize) !void {
        if (wanted <= self.buffer.len) return;

        const bigger = try self.allocator.alloc(i32, wanted);
        @memcpy(bigger[0..self.len], self.items());
        self.allocator.free(self.buffer);
        self.buffer = bigger;

        self.growths += 1;
        self.carried += self.len;
    }

    /// Doubling, which is the choice that makes append amortised O(1).
    /// Growing by a fixed number of slots instead would make building an
    /// array of n items cost O(n^2), because the copy happens n/k times and
    /// each one copies an average of n/2 items.
    fn append(self: *Array, value: i32) !void {
        if (self.len == self.buffer.len) {
            try self.ensureCapacity(if (self.buffer.len == 0) 1 else self.buffer.len * 2);
        }
        self.buffer[self.len] = value;
        self.len += 1;
    }

    fn pop(self: *Array) ?i32 {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.buffer[self.len];
    }

    /// Hand the memory to the caller and empty the array. The buffer is
    /// trimmed to the live values first, so the caller is not handed the
    /// unused capacity it never asked for and would have to free anyway.
    fn toOwnedSlice(self: *Array) ![]i32 {
        const exact = try self.allocator.alloc(i32, self.len);
        @memcpy(exact, self.items());
        self.allocator.free(self.buffer);
        self.buffer = &.{};
        self.len = 0;
        return exact;
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    var array = Array.init(allocator);
    defer array.deinit();

    // Every append that finds len == capacity pays for a copy. Watching the
    // capacity rather than being told the rule is the point of this loop.
    try out.writeAll("appending 1..16\n");
    for (1..17) |i| {
        const growths_before = array.growths;
        const carried_before = array.carried;
        try array.append(@intCast(i));
        if (array.growths != growths_before) {
            try out.print(
                "  append {d:>2}: capacity {d:>2}, copied {d:>2}\n",
                .{ i, array.buffer.len, array.carried - carried_before },
            );
        }
    }
    try out.print(
        "16 appends: {d} growths, {d} values copied in total\n\n",
        .{ array.growths, array.carried },
    );

    // The amortised claim, checked rather than asserted in prose.
    try out.print("copies < 2 * appends -> {}\n\n", .{array.carried < 2 * array.len});

    try out.print("len={d} capacity={d} last={d}\n", .{ array.len, array.buffer.len, array.items()[15] });

    // Reserving ahead removes every growth from the loop that follows, and
    // with no growth the buffer does not move.
    try array.ensureCapacity(64);
    const reserved_ptr = array.buffer.ptr;
    for (17..40) |i| try array.append(@intCast(i));
    try out.writeAll("after reserving 64, then 23 more appends:\n");
    try out.print("  len={d} capacity={d} growths={d}\n", .{ array.len, array.buffer.len, array.growths });
    try out.print("  buffer moved during those 23 appends -> {}\n\n", .{reserved_ptr != array.buffer.ptr});

    try out.print("pop() -> {?d}, len is now {d}\n", .{ array.pop(), array.len });

    const buffers_allocated = array.growths;
    const owned = try array.toOwnedSlice();
    defer allocator.free(owned);
    try out.print(
        "toOwnedSlice: caller holds {d} values, array is len={d} capacity={d}\n",
        .{ owned.len, array.len, array.buffer.len },
    );

    // One allocation holding many values, against one allocation per value.
    // That difference is why this is the container to reach for first, and
    // why the next chapters have to earn their pointers.
    try out.print("\nreaching 39 values took {d} buffer allocations\n", .{buffers_allocated});
    try out.writeAll("the same values in a linked list take one allocation each\n");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.growable-array`)*

## Length and capacity are different numbers

```zig
const Array = struct {
    buffer: []i32 = &.{},
    len: usize = 0,
    allocator: std.mem.Allocator,
};
```

`buffer.len` is how many values would fit. `len` is how many are actually
there, and it is never larger. The live values are `buffer[0..len]`.

An empty array allocates nothing. `&.{}` is a slice of length zero with no
allocation behind it, so `init` cannot fail and an array that never receives
an append never touches the allocator.

## Doubling is what makes append cheap

An append that finds `len == buffer.len` has nowhere to put the value. It
allocates a larger buffer, copies the values across, and frees the old one.
The size it asks for is what decides the cost of everything built on top:

```zig
if (self.len == self.buffer.len) {
    try self.ensureCapacity(if (self.buffer.len == 0) 1 else self.buffer.len * 2);
}
```

The program counts the copies rather than asserting the result:

```
append  1: capacity  1, copied  0
append  2: capacity  2, copied  1
append  3: capacity  4, copied  2
append  5: capacity  8, copied  4
append  9: capacity 16, copied  8
16 appends: 5 growths, 15 values copied in total
```

Sixteen appends copied fifteen values. The copies form a geometric series, so
their total stays below the final length however far the array grows, and the
average cost of an append settles to a constant. Amortised O(1) is a property
of the doubling, not of the copy being fast.

Growing by a fixed number of slots breaks it. Eight extra slots per growth
means a copy every eighth append, each one copying the entire array, and
building `n` values costs O(n^2).

## Growing moves the buffer

`ensureCapacity` allocates, copies and frees, in that order. The address
changes, so a pointer or slice taken before a growth points into memory that
has been handed back:

```zig
const bigger = try self.allocator.alloc(i32, wanted);
@memcpy(bigger[0..self.len], self.items());
self.allocator.free(self.buffer);
self.buffer = bigger;
```

Nothing marks the old slice as dead. It still holds a valid pointer and a
valid length, and it reads whatever the allocator put there next. Take the
slice when you need it and do not keep it across an append.

`std.ArrayList` has the same hazard for the same reason, and it now ships
`lockPointers` to turn the mistake into a panic in a safety build.
[ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/) covers both.

Written with `Allocator.realloc` this is one call, and the copy is sometimes
skipped when the allocation can be extended where it already sits. The three
steps are spelled out here because the copy is the thing being counted.

## Reserving removes the growth

When the final size is known, ask for it once:

```
after reserving 64, then 23 more appends:
  len=39 capacity=64 growths=6
  buffer moved during those 23 appends -> false
```

Twenty-three appends, no allocation and no copy. The buffer stays where it is,
so a pointer taken after the reserve survives all of them.

It is also why the standard library separates `append` from
`appendAssumeCapacity`. Once the room is reserved the append cannot fail, so
the version that assumes the space returns no error.

## What the standard library gives you

`std.ArrayList` is this structure with a type parameter, alignment handling,
and a growth policy tuned at the margins. The names line up: `items` is a
field rather than a method, `ensureCapacity` is `ensureTotalCapacity`, and
`toOwnedSlice` does what it does here.

Reaching thirty-nine values took six allocations. The same values in a linked
list take thirty-nine, one for every node, scattered wherever the allocator
had room. The next chapter builds that list.
