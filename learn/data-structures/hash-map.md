# A Hash Map from Scratch

> Open addressing with linear probing, growth at 75%, and the tombstone. The tombstone looks like a hack, but it makes delete work.

A hash map changes a key into an index and looks at that index. All of the difficult parts of a hash map come from one fact: sometimes two keys get the same index.

This version uses open addressing. Each entry is in the array itself. When a collision occurs, the map tries the next slot.

The alternative is separate chaining, where each bucket has a linked list. Most textbooks show separate chaining. `std` uses open addressing, and almost all modern implementations use it too. A probe that moves forward through one array touches far fewer cache lines than a probe that follows pointers.

```zig
const std = @import("std");

const Map = struct {
    entries: []Entry,
    count: usize = 0,
    /// Live entries plus tombstones. The cost of a probe depends on this
    /// value, not on `count`. Thus a map that you fill and empty many times
    /// must still grow.
    occupied: usize = 0,
    allocator: std.mem.Allocator,

    const Entry = struct {
        key: []const u8 = &.{},
        value: i32 = 0,
        state: enum { empty, used, tombstone } = .empty,
    };

    /// Grow at 75%. A higher limit puts more into the same memory and makes
    /// each probe longer. A lower limit wastes memory. Three quarters is the
    /// usual compromise. The arithmetic below uses no floats: it compares
    /// `4 * (occupied + 1)` to `3 * capacity`.
    const load_numerator = 3;
    const load_denominator = 4;

    fn init(allocator: std.mem.Allocator, capacity: usize) !Map {
        // A power of two, so that the modulo is a mask. A prime capacity
        // needs a full division on each probe.
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

    /// The slot for a key, and the number of steps to get to that slot.
    ///
    /// Linear probing: on collision, try the next slot. It has the best cache
    /// behaviour of all probe sequences, because the next slot is usually in
    /// the same cache line. It also has the worst clustering, because runs of
    /// occupied slots join and grow.
    fn probe(self: *const Map, key: []const u8) struct { index: usize, steps: usize } {
        const mask = self.entries.len - 1;
        var index: usize = @intCast(hash(key) & mask);
        var steps: usize = 1;
        var first_tombstone: ?usize = null;

        while (true) : (steps += 1) {
            const entry = &self.entries[index];
            switch (entry.state) {
                // An insert can use a tombstone again, but only after the
                // probe confirms that the key is not farther along the chain.
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
    /// This is a separate function, because `grow` must insert each live
    /// entry again. If `grow` called `put`, `put` would check the load factor
    /// of the buffer that `grow` fills. Zig finds that shape at compile time.
    /// Two functions with inferred error sets that call each other make a
    /// dependency loop, and the error gives the names of the two functions.
    fn insertNoGrow(self: *Map, key: []const u8, value: i32) void {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used) {
            self.count += 1;
            if (entry.state == .empty) self.occupied += 1;
        }
        entry.* = .{ .key = key, .value = value, .state = .used };
    }

    /// Delete leaves a marker, not an empty slot.
    fn remove(self: *Map, key: []const u8) bool {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used or !std.mem.eql(u8, entry.key, key)) return false;
        entry.* = .{ .state = .tombstone };
        self.count -= 1;
        return true;
    }

    /// The bug that explanations of this structure usually show. If you
    /// empty the slot, you break each probe chain that went through it.
    fn removeWithoutTombstone(self: *Map, key: []const u8) bool {
        const slot = self.probe(key);
        const entry = &self.entries[slot.index];
        if (entry.state != .used or !std.mem.eql(u8, entry.key, key)) return false;
        entry.* = .{ .state = .empty };
        self.count -= 1;
        return true;
    }

    /// Rehash into a buffer of double the size. The rehash does not copy the
    /// tombstones. Their removal is the other purpose of growth.
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

    // Delete a third of the keys, and confirm that the program can still get
    // to the other keys. Each of these deletes leaves a tombstone.
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

    // The same experiment without the tombstone. No error occurs, and no
    // memory becomes corrupt. The map does not find some keys, because a
    // probe that walked past a full slot before now stops at an empty slot.
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

    // The map from std, for the same keys. It also uses open addressing. Its
    // metadata bytes are separate from the entries. Thus a probe scans a small
    // array of one-byte fingerprints, not the full-size entries.
    var std_map: std.StringHashMapUnmanaged(i32) = .empty;
    defer std_map.deinit(allocator);
    for (keys, 1..) |key, i| try std_map.put(allocator, key, @intCast(i));
    try out.print("\nstd.StringHashMap: {d} entries, get(\"nim\") -> {?d}\n", .{
        std_map.count(), std_map.get("nim"),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.hash-map`)*

## The capacity is a power of two

```zig
var index: usize = @intCast(hash(key) & mask);
```

With a capacity that is a power of two, the modulo is a bitwise and. A prime capacity spreads the results of a weak hash function better. But a prime capacity costs a real division on each probe step. The modern answer is a power of two, plus a hash function that is good enough without the prime. `std.hash.Wyhash` has this purpose.

## Linear probing, and its known flaw

On a collision, try the next slot. Linear probing has the best cache behaviour of all probe sequences. The reason is that the next slot is usually in the cache line that the CPU already loaded.

Linear probing also has the worst clustering. Two separate runs of occupied slots can grow until they touch. Then they become one longer run. Each key with a hash anywhere in that run must then probe through all of the run. The output shows the effect:

```
after inserts: 14 live,  0 tombstones, capacity 32, mean probe 1.57, worst 6
```

The map finds most keys on the first try, but one key needed six steps. Quadratic probing and double hashing scatter the probes to prevent clustering. The cost is the cache locality that made linear probing attractive.

## Growth depends on the load factor

```zig
if ((self.occupied + 1) * load_denominator > self.entries.len * load_numerator) {
    try self.grow();
}
```

When the table is 75% full, allocate double the space and insert all the entries again. A higher limit puts more entries into the same memory, but it makes each probe longer. The cost of a probe increases quickly as the table fills, because a table that is almost full has long runs. Three quarters is the usual compromise.

Look at what the check counts. `occupied` is the live entries *plus* the tombstones, not `count`. If you fill and empty a map many times, it collects tombstones, and it must still grow. The length of a probe depends on the number of slots that are not empty. It does not depend on the number of slots that hold real data.

Growth is also the only operation that removes tombstones. A rehash into a new buffer does not copy the tombstones.

## The tombstone

A delete cannot only empty the slot:

```zig
entry.* = .{ .state = .tombstone };
```

This line looks like an unnecessary complication, until you remove it. The snippet does the same deletes in the two ways:

```
removed 5 keys with tombstones
survivors still reachable: 9 of 9

same deletes, clearing the slot instead:
survivors still reachable: 7 of 9
lost by breaking the probe chain: 2
```

Two keys became unreachable. No error occurred, and no memory became corrupt. These are the steps of each failed lookup:

1. The lookup walked to the correct position for the key.
2. It found an empty slot, where a full slot was before.
3. It decided that the key was not in the map.
4. It returned null.

A probe chain is a run of occupied slots. If the home slot of a key is earlier in that run, the key needs all of the run to stay unbroken. When you empty a slot in the middle, you cut each chain that went through that slot. The tombstone says "continue, something was here before". The chain needs exactly that information.

The insert must also handle the tombstone correctly. The probe remembers the first tombstone that it sees, but it continues the walk, because the key can already exist farther along the chain. Only when the probe gets to an empty slot does it return to the tombstone and use it again. If the probe used the tombstone immediately, the same key could go into the map two times.

## Delete correctly without tombstones

One method is backward-shift deletion. After you remove an entry, walk forward through the rest of the run. Move an entry back to its home slot if the removal made space for it. This method keeps the table free of tombstones, but each delete costs more work. Robin Hood hashing usually uses this method. Thus tombstones are a design choice: cheaper deletes, or shorter probes.

## What std does differently

```zig
var std_map: std.StringHashMapUnmanaged(i32) = .empty;
try std_map.put(allocator, key, 1);
```

[Hash maps](https://www.ziglang.in/learn/standard-library/hash-maps/) explains the API. The main structural difference is that `std` stores a separate array of one-byte metadata next to the entries. Each byte holds a few bits of the hash of the key, plus the empty and tombstone flags.

A probe scans that small byte array, not the full-size entries. Thus many more probe steps fit in a cache line. Also, a comparison of one byte can show that a key is not the correct key, before the probe touches the entry. Because of that layout, the same algorithm performs very differently in `std` and in a simple implementation like this one.

[ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/) uses the same pattern on master: the `Unmanaged` suffix, and an allocator argument on each method. The container does not store the allocator.

## The map borrows its keys

The map in this chapter stores `[]const u8` keys, but it does not copy them. Thus the caller must keep the strings alive. For the string literals in the snippet, this is not a problem, because they are in the binary. But if you store a key from a buffer that you use again later, the map points at the new data in that buffer.

`std.StringHashMap` has the same property. For this reason, helpers in the style of `putClone`, and arenas, are frequently used together with it. A container that borrows must tell you so, and this chapter tells you here.
