//! A fixed-capacity pool with generational handles.
//!
//! This game creates and destroys entities all the time. The game spawns a
//! block above the top of the screen, and frees the block when it leaves the
//! bottom. This occurs several times each second, for all of the game. This
//! has two results.
//!
//! The storage is a fixed array. Thus a run of any length allocates exactly
//! one time (at startup) and never again. The simulation has no allocator.
//!
//! The references to entities are handles, not pointers. A handle contains the
//! slot index *and* the generation of that slot at the time when the pool made
//! the handle. When the pool frees a slot, it increments the generation of the
//! slot. Thus no handle to the old occupant resolves after that.
//!
//! Without this rule, an event can live one frame longer than its entity. An
//! example is a coin that the player collected, or a block that the game
//! removed. That event would read the new value in the slot. This type of bug gives a wrong
//! score one time each hour, and you can never reproduce it.

const std = @import("std");

pub fn Pool(comptime T: type, comptime capacity_in: u16) type {
    return struct {
        const Self = @This();

        pub const capacity = capacity_in;

        pub const Handle = struct {
            index: u16,
            generation: u32,

            /// A handle that never resolves. The pool never gives out
            /// generation 0, because live slots start at generation 1.
            pub const none: Handle = .{ .index = 0, .generation = 0 };

            pub fn eql(a: Handle, b: Handle) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const Slot = struct {
            value: T,
            /// Odd while the slot is live, even while it is free.
            generation: u32,
            /// The index of the next free slot. It is valid only while this
            /// slot is free.
            next_free: u16,
        };

        slots: [capacity]Slot,
        free_head: u16,
        live: u16,

        pub const empty = init: {
            var self: Self = .{
                .slots = undefined,
                .free_head = 0,
                .live = 0,
            };
            for (&self.slots, 0..) |*slot, i| {
                slot.* = .{
                    .value = undefined,
                    .generation = 0,
                    .next_free = @intCast(i + 1),
                };
            }
            break :init self;
        };

        /// Returns null when the pool is full. The caller decides what a full
        /// pool means. The spawner uses a full pool as back-pressure and does
        /// not do the spawn. This is always safe, because the course stays
        /// solvable.
        pub fn create(self: *Self, value: T) ?Handle {
            if (self.free_head >= capacity) return null;
            const index = self.free_head;
            const slot = &self.slots[index];
            self.free_head = slot.next_free;
            slot.generation += 1; // even -> odd: now live
            slot.value = value;
            self.live += 1;
            return .{ .index = index, .generation = slot.generation };
        }

        pub fn destroy(self: *Self, handle: Handle) void {
            const slot = self.resolve(handle) orelse return;
            slot.generation += 1; // odd -> even: now free
            slot.next_free = self.free_head;
            self.free_head = handle.index;
            self.live -= 1;
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            const slot = self.resolve(handle) orelse return null;
            return &slot.value;
        }

        pub fn contains(self: *const Self, handle: Handle) bool {
            if (handle.index >= capacity) return false;
            const slot = &self.slots[handle.index];
            return slot.generation == handle.generation and slot.generation % 2 == 1;
        }

        fn resolve(self: *Self, handle: Handle) ?*Slot {
            if (handle.index >= capacity) return null;
            const slot = &self.slots[handle.index];
            if (slot.generation != handle.generation) return null;
            if (slot.generation % 2 == 0) return null;
            return slot;
        }

        pub const Entry = struct { handle: Handle, value: *T };

        pub const Iterator = struct {
            pool: *Self,
            index: u16 = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < capacity) {
                    const i = self.index;
                    self.index += 1;
                    const slot = &self.pool.slots[i];
                    if (slot.generation % 2 == 1) return .{
                        .handle = .{ .index = i, .generation = slot.generation },
                        .value = &slot.value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        pub fn clear(self: *Self) void {
            var it = self.iterator();
            while (it.next()) |entry| self.destroy(entry.handle);
        }
    };
}

const TestPool = Pool(i32, 4);

test "create then get round-trips" {
    var pool: TestPool = .empty;
    const h = pool.create(42).?;
    try std.testing.expectEqual(@as(i32, 42), pool.get(h).?.*);
    try std.testing.expectEqual(@as(u16, 1), pool.live);
}

test "a handle stops resolving once its slot is freed" {
    var pool: TestPool = .empty;
    const h = pool.create(7).?;
    pool.destroy(h);
    try std.testing.expect(pool.get(h) == null);
    try std.testing.expect(!pool.contains(h));
    try std.testing.expectEqual(@as(u16, 0), pool.live);
}

test "a stale handle does not resolve to the slot's new occupant" {
    var pool: TestPool = .empty;
    const old = pool.create(1).?;
    pool.destroy(old);
    const new = pool.create(2).?;
    // The pool uses the freed slot again. This is the purpose of the pool.
    try std.testing.expectEqual(old.index, new.index);
    // The stale handle must not see the new value.
    try std.testing.expect(pool.get(old) == null);
    try std.testing.expectEqual(@as(i32, 2), pool.get(new).?.*);
}

test "the null handle never resolves" {
    var pool: TestPool = .empty;
    _ = pool.create(1).?;
    try std.testing.expect(pool.get(TestPool.Handle.none) == null);
}

test "create returns null when full, and recovers after a free" {
    var pool: TestPool = .empty;
    var handles: [4]TestPool.Handle = undefined;
    for (&handles, 0..) |*h, i| h.* = pool.create(@intCast(i)).?;
    try std.testing.expect(pool.create(99) == null);

    pool.destroy(handles[2]);
    const h = pool.create(99).?;
    try std.testing.expectEqual(@as(i32, 99), pool.get(h).?.*);
}

test "iterator visits exactly the live entries" {
    var pool: TestPool = .empty;
    const a = pool.create(10).?;
    const b = pool.create(20).?;
    const c = pool.create(30).?;
    pool.destroy(b);

    var sum: i32 = 0;
    var count: usize = 0;
    var it = pool.iterator();
    while (it.next()) |entry| {
        sum += entry.value.*;
        count += 1;
        try std.testing.expect(entry.handle.eql(a) or entry.handle.eql(c));
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(i32, 40), sum);
}

test "destroying during iteration is safe" {
    var pool: TestPool = .empty;
    for (0..4) |i| _ = pool.create(@intCast(i)).?;

    var it = pool.iterator();
    while (it.next()) |entry| {
        if (@rem(entry.value.*, 2) == 0) pool.destroy(entry.handle);
    }
    try std.testing.expectEqual(@as(u16, 2), pool.live);

    var remaining: i32 = 0;
    var it2 = pool.iterator();
    while (it2.next()) |entry| remaining += entry.value.*;
    try std.testing.expectEqual(@as(i32, 4), remaining); // 1 + 3
}

test "churn keeps live count honest and handles unique" {
    var pool: TestPool = .empty;
    var rng_state: u32 = 1;
    var held: [4]?TestPool.Handle = .{ null, null, null, null };

    for (0..10_000) |_| {
        rng_state = rng_state *% 1664525 +% 1013904223;
        const slot = (rng_state >> 16) % 4;
        if (held[slot]) |h| {
            try std.testing.expect(pool.contains(h));
            pool.destroy(h);
            held[slot] = null;
        } else {
            held[slot] = pool.create(@intCast(slot));
            try std.testing.expect(held[slot] != null);
        }
        var expected: u16 = 0;
        for (held) |h| {
            if (h != null) expected += 1;
        }
        try std.testing.expectEqual(expected, pool.live);
    }
}

test "clear empties the pool and invalidates every handle" {
    var pool: TestPool = .empty;
    var handles: [4]TestPool.Handle = undefined;
    for (&handles, 0..) |*h, i| h.* = pool.create(@intCast(i)).?;

    pool.clear();
    try std.testing.expectEqual(@as(u16, 0), pool.live);
    for (handles) |h| try std.testing.expect(!pool.contains(h));

    // After the clear, you can use all of the pool again.
    for (0..4) |i| _ = pool.create(@intCast(i)).?;
    try std.testing.expectEqual(@as(u16, 4), pool.live);
}
