//! title: Bit Sets and Enum Collections
//! A set of small integers in a few machine words, and maps keyed by enums.

const std = @import("std");
const expect = std.testing.expect;

test "static bit set" {
    // 64 bits, stored inline. No allocator anywhere.
    var seen: std.StaticBitSet(64) = .empty;

    seen.set(3);
    seen.set(40);
    try expect(seen.isSet(3));
    try expect(!seen.isSet(4));
    try expect(seen.count() == 2);

    // Iterates set bit indices in ascending order.
    var it = seen.iterator(.{});
    try expect(it.next().? == 3);
    try expect(it.next().? == 40);
    try expect(it.next() == null);
}

test "set algebra" {
    var a: std.StaticBitSet(16) = .empty;
    var b: std.StaticBitSet(16) = .empty;
    a.set(1);
    a.set(2);
    b.set(2);
    b.set(3);

    const both = a.intersectWith(b);
    try expect(both.count() == 1 and both.isSet(2));

    const either = a.unionWith(b);
    try expect(either.count() == 3);
}

test "ranges" {
    var mask: std.StaticBitSet(32) = .empty;
    mask.setRangeValue(.{ .start = 8, .end = 16 }, true);
    try expect(mask.count() == 8);
    try expect(mask.findFirstSet().? == 8);
}

const Perm = enum { read, write, execute };

test "EnumSet: a bit set keyed by an enum" {
    var perms = std.EnumSet(Perm).initMany(&.{ .read, .write });

    try expect(perms.contains(.read));
    try expect(!perms.contains(.execute));

    perms.insert(.execute);
    perms.remove(.write);
    try expect(perms.count() == 2);
}

const Light = enum { red, yellow, green };

test "EnumArray: one value per enum tag, no optionals" {
    // Every key exists; initialization must cover all of them.
    var durations = std.EnumArray(Light, u32).init(.{
        .red = 30,
        .yellow = 5,
        .green = 25,
    });

    try expect(durations.get(.red) == 30);
    durations.set(.yellow, 4);
    try expect(durations.get(.yellow) == 4);
}

test "EnumMap: some keys may be absent" {
    var overrides = std.EnumMap(Light, u32).init(.{ .red = 45 });

    try expect(overrides.get(.red).? == 45);
    try expect(overrides.get(.green) == null);

    overrides.put(.green, 20);
    try expect(overrides.count() == 2);
}
