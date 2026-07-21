//! title: Enums
//! Named values with an integer representation, and methods.

const std = @import("std");
const expect = std.testing.expect;

const Direction = enum { north, south, east, west };

// The tag type can be pinned, which fixes the numeric values.
const Value = enum(u8) { zero = 0, one = 1, hundred = 100 };

const Suit = enum {
    clubs,
    spades,
    diamonds,
    hearts,

    // Enums can have methods; they are namespaced functions, not vtables.
    pub fn isRed(self: Suit) bool {
        return switch (self) {
            .diamonds, .hearts => true,
            .clubs, .spades => false,
        };
    }
};

test "enum values" {
    try expect(@intFromEnum(Value.zero) == 0);
    try expect(@intFromEnum(Value.hundred) == 100);
}

test "inferred enum literals" {
    // When the type is known, `.north` is enough.
    const d: Direction = .north;
    try expect(d == Direction.north);
}

test "enum methods" {
    try expect(Suit.hearts.isRed());
    try expect(!Suit.spades.isRed());
}

test "enums expose their fields at comptime" {
    try expect(@typeInfo(Direction).@"enum".fields.len == 4);
    try expect(std.mem.eql(u8, @tagName(Direction.east), "east"));
}
