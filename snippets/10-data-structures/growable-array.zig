//! title: A Growable Array
//! The container that all other containers assume. A length, a capacity, and
//! one rule for when the length reaches the capacity. A growth has a cost, and
//! a growth makes your old pointer into the buffer invalid.

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
