//! title: Hash Maps
//! Key-value storage, also unmanaged by default.

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
