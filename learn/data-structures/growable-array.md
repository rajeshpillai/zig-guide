# A Growable Array

> A length, a capacity, and one rule for what occurs when the length reaches the capacity.

A growable array is an array whose length can change. The standard library calls it `ArrayList`. Most programs use it first, and many programs never need a different container.

The structure has three fields and one rule. The rule tells what occurs when the values fill all of the space. All of the cost of the structure comes from that rule.

```zig
const std = @import("std");

/// This array holds only `i32`, on purpose. The next chapter changes it to
/// hold any type. That change is smaller than it looks.
const Array = struct {
    /// The full allocation. `buffer.len` is the capacity: the number of items
    /// that fit, not the number of items that are there.
    buffer: []i32 = &.{},
    /// The number of slots that hold a value. Always <= buffer.len.
    len: usize = 0,
    allocator: std.mem.Allocator,

    /// Counters, so that the output can show the growth policy.
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

    /// The live values. A slice into the buffer, valid until the next growth.
    /// The main hazard of this structure is a slice used after a growth.
    fn items(self: *const Array) []i32 {
        return self.buffer[0..self.len];
    }

    /// Make space for at least `wanted` slots.
    ///
    /// This function does three steps (allocate, copy, free) and does not use
    /// `realloc`. A growth is those three steps, and the program counts the
    /// copy. `Allocator.realloc` does the same steps. It can omit the copy
    /// when it can make the allocation larger at its current address.
    fn ensureCapacity(self: *Array, wanted: usize) !void {
        if (wanted <= self.buffer.len) return;

        const bigger = try self.allocator.alloc(i32, wanted);
        @memcpy(bigger[0..self.len], self.items());
        self.allocator.free(self.buffer);
        self.buffer = bigger;

        self.growths += 1;
        self.carried += self.len;
    }

    /// The capacity doubles. This choice makes append amortised O(1).
    /// If the array grows by a fixed number k of slots, an array of n items
    /// costs O(n^2). The copy occurs n/k times, and each copy moves an
    /// average of n/2 items.
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

    /// Give the memory to the caller and make the array empty. First, the
    /// function cuts the buffer to the live values. Thus the caller does not
    /// get unused capacity that it did not ask for and must free.
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

    // Each append that finds len == capacity must copy. This loop prints
    // the capacity, so that you can see the rule.
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

    // Check the amortised claim with a count.
    try out.print("copies < 2 * appends -> {}\n\n", .{array.carried < 2 * array.len});

    try out.print("len={d} capacity={d} last={d}\n", .{ array.len, array.buffer.len, array.items()[15] });

    // A reserve before the loop removes all growths from the loop. With no
    // growth, the buffer does not move.
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

    // One allocation holds many values here. A linked list needs one
    // allocation for each value. Thus this is the container to use first.
    // The containers in the next chapters use pointers, and that cost must
    // have a good reason.
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

`buffer.len` is the number of values that the buffer can hold. `len` is the number of values that are in the buffer, and `len` is never larger than `buffer.len`. The live values are `buffer[0..len]`.

An empty array allocates no memory. `&.{}` is a slice of length zero with no allocation behind it. Thus `init` cannot fail. If an array gets no append, the array never uses the allocator.

## Double the capacity to make append cheap

When an append finds `len == buffer.len`, the buffer has no space for the value. The append allocates a larger buffer, copies the values into the new buffer, and frees the old buffer. The size of the new buffer decides the cost of all the operations that use the array:

```zig
if (self.len == self.buffer.len) {
    try self.ensureCapacity(if (self.buffer.len == 0) 1 else self.buffer.len * 2);
}
```

The program counts the copies. It does not only assert the result:

```
  append  1: capacity  1, copied  0
  append  2: capacity  2, copied  1
  append  3: capacity  4, copied  2
  append  5: capacity  8, copied  4
append  9: capacity 16, copied  8
16 appends: 5 growths, 15 values copied in total
```

Sixteen appends copied fifteen values. The copies make a geometric series. Thus the total number of copies stays below the final length, for all sizes of the array. The average cost of an append becomes a constant. Amortised O(1) is a property of the rule that doubles the capacity. It is not a property of a fast copy.

If the array grows by a fixed number of slots, this property is lost. With eight extra slots for each growth, a copy occurs on each eighth append, and each copy moves the full array. Then the cost to put `n` values in the array is O(n^2).

## Growth moves the buffer

`ensureCapacity` allocates, copies and frees, in that order. The address of the buffer changes. Thus a pointer or a slice that you got before a growth points into memory that the array gave back to the allocator:

```zig
const bigger = try self.allocator.alloc(i32, wanted);
@memcpy(bigger[0..self.len], self.items());
self.allocator.free(self.buffer);
self.buffer = bigger;
```

Nothing marks the old slice as dead. The old slice still has a valid pointer and a valid length. It reads the data that the allocator put in that memory after the free. Get the slice when you need it. Do not keep the slice across an append.

`std.ArrayList` has the same problem for the same reason. It now has `lockPointers`, which changes the mistake into a panic in a safety build. [ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/) explains both.

With `Allocator.realloc`, the three steps are one call. Sometimes `realloc` does not copy, because it can make the allocation larger at its current address. This chapter shows the three steps separately, because the program counts the copy.

## Reserve space to remove the growth

When you know the final size, ask for it one time:

```
after reserving 64, then 23 more appends:
  len=39 capacity=64 growths=6
  buffer moved during those 23 appends -> false
```

The twenty-three appends cause no allocation and no copy. The buffer stays at the same address. Thus a pointer that you get after the reserve stays valid during all of these appends.

This is also the reason that the standard library has two functions, `append` and `appendAssumeCapacity`. When you reserve the space, an append cannot fail. Thus the version that assumes the space returns no error.

## What the standard library gives you

`std.ArrayList` is this structure with a type parameter, support for alignment, and a growth policy with small adjustments. The names agree:

- `items` is a field, not a method.
- `ensureCapacity` is `ensureTotalCapacity`.
- `toOwnedSlice` does the same thing as in this chapter.

Thirty-nine values needed six allocations. In a linked list, the same values need thirty-nine allocations, one for each node. These nodes are at the addresses where the allocator had space. The next chapter builds that list.
