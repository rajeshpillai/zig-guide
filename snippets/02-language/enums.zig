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

test "enums expose their tags at comptime" {
    const info = @typeInfo(Direction).@"enum";

    // Names and values are parallel arrays, not one array of field structs.
    try expect(info.field_names.len == 4);
    try expect(info.field_values.len == info.field_names.len);
    try expect(std.mem.eql(u8, info.field_names[2], "east"));

    try expect(info.tag_type == u2);
    try expect(info.mode == .exhaustive);

    try expect(std.mem.eql(u8, @tagName(Direction.east), "east"));
}
