//! title: Unions
//! One of several types, in one piece of memory.

const std = @import("std");
const expect = std.testing.expect;

// A bare union has no tag: you must know which field is active.
const Payload = union {
    int: i64,
    float: f64,
};

const Tag = enum { int, float, none };

// A tagged union carries its tag, so `switch` can safely discriminate.
const Tagged = union(Tag) {
    int: i64,
    float: f64,
    none: void,
};

// `union(enum)` infers the tag enum for you.
const Inferred = union(enum) {
    text: []const u8,
    number: u32,
};

test "bare union" {
    var p = Payload{ .int = 42 };
    try expect(p.int == 42);
    // Reading `p.float` here would be illegal behaviour: wrong active field.
    p = Payload{ .float = 1.5 };
    try expect(p.float == 1.5);
}

test "switch on a tagged union" {
    var value = Tagged{ .int = 7 };
    switch (value) {
        .int => |*n| n.* += 1,
        .float => |*f| f.* *= 2,
        .none => {},
    }
    try expect(value.int == 8);
}

test "the tag is a real enum value" {
    const value = Tagged{ .float = 2.5 };
    try expect(@as(Tag, value) == .float);
}

test "inferred tag enum" {
    const v = Inferred{ .text = "hi" };
    switch (v) {
        .text => |t| try expect(t.len == 2),
        .number => unreachable,
    }
}
