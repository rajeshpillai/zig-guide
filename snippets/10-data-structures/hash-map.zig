//! title: A Hash Map from Scratch
//! Open addressing in about a hundred lines: probe on collision, grow on load,
//! and leave a tombstone on delete. The last one looks like a hack until you
//! delete without it and watch a lookup fail.

const std = @import("std");

const Map = struct {
    entries: []Entry,
    count: usize = 0,
    /// Live entries plus tombstones. Probing cost depends on this, not on
    /// `count`, which is why a map that is repeatedly filled and emptied still
    /// needs to grow.
    occupied: usize = 0,
    allocator: std.mem.Allocator,

    const Entry = struct {
        key: []const u8 = &.{},
        value: i32 = 0,
        state: enum { empty, used, tombstone } = .empty,
    };

    /// Grow at 75%. Higher packs more into the same memory and lengthens every
    /// probe; lower wastes memory. Three quarters is the usual compromise, and
    /// the arithmetic below avoids floats by comparing `4 * occupied` to
    /// `3 * capacity`.
    const load_numerator = 3;
    const load_denominator = 4;

    fn init(allocator: std.mem.Allocator, capacity: usize) !Map {
        // A power of two so the modulo is a mask. With a prime capacity you
        // would need a real division on every probe.
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        return .{ .entries = entries, .allocator = allocator };
    }

    fn deinit(self: *Map) void {
        self.allocator.free(self.entries);
        self.entries = &.{};
    }

    fn hash(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    /// Where a key belongs, and how many steps it took to get there.
    ///
    /// Linear probing: on collision, try the next slot. It has the best cache
    /// behaviour of any probe sequence because the next slot is usually the
    /// same cache line, and the worst clustering, because runs of occupied
    /// slots merge and grow.
    fn probe(self: *const Map, key: []const u8) struct { index: usize, steps: usize } {
        const mask = self.entries.len - 1;
        var index: usize = @intCast(hash(key) & mask);
        var steps: usize = 1;
        var first_tombstone: ?usize = null;

        while (true) : (steps += 1) {
            const entry = &self.entries[index];
            switch (entry.state) {
                // Insertion may reuse a tombstone, but only after confirming
                // the key is not further along the chain.
                .empty => return .{ .index = first_tombstone orelse index, .steps = steps },
                .tombstone => {
                    if (first_tombstone == null) first_tombstone = index;
                },
                .used => if (std.mem.eql(u8, entry.key, key)) return .{ .index = index, .steps = steps },
            }
            index = (index + 1) & mask;
        }
    }

    fn get(self: *const Map, key: []const u8) ?i32 {
        const slot = self.probe(key);
        const entry = self.entries[slot.index];
        return if (entry.state == .used and std.mem.eql(u8, entry.key, key)) entry.value else null;
    }

    fn put(self: *Map, key: []const u8, value: i32) !void {
        if ((self.occupied + 1) * load_denominator > self.entries.len * load_numerator) {
            try self.grow();
        }

        self.insertNoGrow(key, value);
    }

    /// The insert itself, with no load check.
    ///
    /// Split out because `grow` needs to reinsert every live entry, and a
    /// `grow` that called `put` would be checking the load factor of the buffer
    /// it is in the middle of filling. Zig catches that particular shape at
    /// compile time: two functions with inferred error sets calling each other
    /// is a dependency loop, and the error names both ends.
    fn insertNoGrow(self: *Map, key: []const u8, value: i32) void {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used) {
            self.count += 1;
            if (entry.state == .empty) self.occupied += 1;
        }
        entry.* = .{ .key = key, .value = value, .state = .used };
    }

    /// Delete leaves a marker rather than an empty slot.
    fn remove(self: *Map, key: []const u8) bool {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used or !std.mem.eql(u8, entry.key, key)) return false;
        entry.* = .{ .state = .tombstone };
        self.count -= 1;
        return true;
    }

    /// The bug this structure is usually explained with. Clearing the slot
    /// outright breaks every probe chain that ran through it.
    fn removeWithoutTombstone(self: *Map, key: []const u8) bool {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used or !std.mem.eql(u8, entry.key, key)) return false;
        entry.* = .{ .state = .empty };
        self.count -= 1;
        return true;
    }

    /// Rehash into a buffer twice the size. Tombstones are not carried over,
    /// which is the other thing growth is for.
    fn grow(self: *Map) !void {
        const old = self.entries;
        const bigger = try self.allocator.alloc(Entry, old.len * 2);
        @memset(bigger, .{});

        self.entries = bigger;
        self.count = 0;
        self.occupied = 0;

        for (old) |entry| {
            if (entry.state == .used) self.insertNoGrow(entry.key, entry.value);
        }
        self.allocator.free(old);
    }

    fn writeStats(self: *const Map, out: *std.Io.Writer, label: []const u8) !void {
        var total_steps: usize = 0;
        var worst: usize = 0;
        var tombstones: usize = 0;

        for (self.entries) |entry| {
            if (entry.state == .tombstone) tombstones += 1;
            if (entry.state != .used) continue;
            const steps = self.probe(entry.key).steps;
            total_steps += steps;
            worst = @max(worst, steps);
        }

        const mean_hundredths = if (self.count == 0) 0 else (total_steps * 100) / self.count;
        try out.print(
            "{s:>16}: {d:>2} live, {d:>2} tombstones, capacity {d:>2}, mean probe {d}.{d:0>2}, worst {d}\n",
            .{ label, self.count, tombstones, self.entries.len, mean_hundredths / 100, mean_hundredths % 100, worst },
        );
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    const keys = [_][]const u8{
        "zig",   "rust", "c",      "go",     "odin",
        "nim",   "d",    "swift",  "kotlin", "julia",
        "ocaml", "elm",  "erlang", "elixir",
    };

    var map = try Map.init(allocator, 8);
    defer map.deinit();

    try out.writeAll("inserting 14 keys into a map that starts at capacity 8:\n");
    for (keys, 1..) |key, i| {
        const before = map.entries.len;
        try map.put(key, @intCast(i));
        if (map.entries.len != before) {
            try out.print("  grew {d} -> {d} while inserting \"{s}\"\n", .{ before, map.entries.len, key });
        }
    }
    try map.writeStats(out, "after inserts");

    try out.print("\nget(\"zig\")    -> {?d}\n", .{map.get("zig")});
    try out.print("get(\"elixir\") -> {?d}\n", .{map.get("elixir")});
    try out.print("get(\"perl\")   -> {?d}\n", .{map.get("perl")});

    // Delete a third of the keys and confirm the rest are still reachable.
    // Every one of these leaves a tombstone behind.
    var removed: usize = 0;
    for (keys, 0..) |key, i| {
        if (i % 3 == 0 and map.remove(key)) removed += 1;
    }
    try out.print("\nremoved {d} keys with tombstones\n", .{removed});
    try map.writeStats(out, "after removes");

    var found: usize = 0;
    for (keys, 0..) |key, i| {
        if (i % 3 != 0 and map.get(key) != null) found += 1;
    }
    try out.print("survivors still reachable: {d} of {d}\n", .{ found, keys.len - removed });

    // The same experiment with the tombstone left out. Nothing errors and no
    // memory is corrupted; keys simply stop being found, because a probe that
    // used to walk past a filled slot now stops at an empty one.
    var naive = try Map.init(allocator, 8);
    defer naive.deinit();
    for (keys, 1..) |key, i| try naive.put(key, @intCast(i));

    var naive_removed: usize = 0;
    for (keys, 0..) |key, i| {
        if (i % 3 == 0 and naive.removeWithoutTombstone(key)) naive_removed += 1;
    }

    var naive_found: usize = 0;
    for (keys, 0..) |key, i| {
        if (i % 3 != 0 and naive.get(key) != null) naive_found += 1;
    }
    try out.print("\nsame deletes, clearing the slot instead:\n", .{});
    try out.print("survivors still reachable: {d} of {d}\n", .{ naive_found, keys.len - naive_removed });
    try out.print("lost by breaking the probe chain: {d}\n", .{
        (keys.len - naive_removed) - naive_found,
    });

    // std's map, for the same keys. It is open addressing too, with metadata
    // bytes held apart from the entries so a probe scans a compact array of
    // one-byte fingerprints instead of full-sized entries.
    var std_map: std.StringHashMapUnmanaged(i32) = .empty;
    defer std_map.deinit(allocator);
    for (keys, 1..) |key, i| try std_map.put(allocator, key, @intCast(i));
    try out.print("\nstd.StringHashMap: {d} entries, get(\"nim\") -> {?d}\n", .{
        std_map.count(), std_map.get("nim"),
    });

    try out.flush();
}
