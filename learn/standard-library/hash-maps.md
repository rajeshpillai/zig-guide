# Hash Maps

> Key-value storage, and the getOrPut pattern.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "string keys" {
    const gpa = std.testing.allocator;
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, "one", 1);
    try map.put(gpa, "two", 2);

    try expect(map.get("one").? == 1);
    try expect(map.get("three") == null);
    try expect(map.count() == 2);
}

test "auto hash for simple keys" {
    const gpa = std.testing.allocator;
    // AutoHashMap derives hashing and equality from the key type.
    var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, 1, "one");
    try expect(std.mem.eql(u8, map.get(1).?, "one"));
}

test "getOrPut avoids hashing twice" {
    const gpa = std.testing.allocator;
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);

    for ([_][]const u8{ "a", "b", "a" }) |word| {
        // One lookup instead of a get followed by a put.
        const entry = try counts.getOrPut(gpa, word);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    try expect(counts.get("a").? == 2);
    try expect(counts.get("b").? == 1);
}

test "iterate entries" {
    const gpa = std.testing.allocator;
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, 1, 10);
    try map.put(gpa, 2, 20);

    var total: u32 = 0;
    var it = map.iterator();
    while (it.next()) |entry| total += entry.value_ptr.*;
    try expect(total == 30);
}

test "remove" {
    const gpa = std.testing.allocator;
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, "gone", 1);
    try expect(map.remove("gone"));
    try expect(map.count() == 0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.hash-maps`)*

## Which map to pick

| Type | For |
| --- | --- |
| `AutoHashMapUnmanaged(K, V)` | keys with derivable hashing (integers, enums, simple structs) |
| `StringHashMapUnmanaged(V)` | `[]const u8` keys |
| `std.array_hash_map.Auto(K, V)` | when you need stable insertion order |

Like `ArrayList`, these are unmanaged: `.empty` to create, allocator passed to
each method that allocates.

`AutoHashMap` will refuse keys it cannot hash safely: slices, for instance,
because hashing the pointer is almost never what you meant. That is why string
keys get their own type.

The refusal is a compile error, not a runtime surprise, and it is one of the
better examples of what comptime reflection buys. The map inspects your key
type at compile time. If it contains a pointer whose target it would have to
follow, it stops and tells you, rather than silently hashing the address.

The third row is the one people miss. A plain hash map's iteration order is
whatever the table's layout produces, and it changes as the map grows. An
array hash map keeps the entries in a list alongside the table, so iterating
gives you insertion order and the cost is one extra indirection. Use it
whenever the output will be shown to a person or compared against a fixture. A
test that iterates a plain hash map is a test that will eventually fail for no
reason.

## `getOrPut` instead of get-then-put

The counting idiom looks like this:

```zig
const entry = try counts.getOrPut(gpa, word);
if (!entry.found_existing) entry.value_ptr.* = 0;
entry.value_ptr.* += 1;
```

One hash and one lookup, rather than two. `entry.value_ptr` points into the
map, so writing through it updates the stored value in place.

Note that pointer is only valid until the next insertion: the same
invalidation rule as `ArrayList.items`.

`entry.key_ptr` is there too, and it matters for the string case below. On a
fresh insert the map has stored *your* slice as the key, and `key_ptr` is
where to overwrite it with a copy you own.

The family is worth knowing in full. `put` overwrites, `putNoClobber` asserts
the key is new, `fetchPut` returns what was there before, and `getOrPutValue`
supplies a default in one call. Each exists so that a common intention is one
operation rather than a lookup followed by a decision.

## Keys are not copied

The map stores your key as given. For string keys that means the map holds a
slice pointing at memory it does not own; if that memory is freed or reused,
the map is corrupt. Either keep the keys alive yourself, or duplicate them on
insert and free them on removal.

The duplicating version is short and worth having a template for:

```zig
const entry = try map.getOrPut(gpa, name);
if (!entry.found_existing) {
    entry.key_ptr.* = try gpa.dupe(u8, name);
    entry.value_ptr.* = 0;
}
```

and the matching teardown iterates the map freeing `entry.key_ptr.*` before
`deinit`. Forgetting that is the most common leak in Zig code that uses maps,
and a leak-checking allocator in a test is what catches it.

You do *not* need to copy when the keys are already owned by something
longer-lived. String literals, names interned in an arena, or slices of a
buffer you are holding for the duration. Then the map borrowing them is
correct and copying would be waste.

## What it costs

A hash map is not free at small sizes. For a handful of entries, a plain array
searched linearly is usually faster and always simpler, because the hashing
and the indirection cost more than scanning eight elements. The map wins when
the count is large enough that O(1) beats O(n) by more than the constant. That
is somewhere in the dozens for cheap keys, and lower for expensive
comparisons.
