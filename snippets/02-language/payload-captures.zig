//! title: Payload Captures
//! `|value|` unwraps whatever the construct is holding.

const std = @import("std");
const expect = std.testing.expect;

const Shape = union(enum) {
    circle: f32,
    rect: struct { w: f32, h: f32 },
};

test "capture an optional" {
    const maybe: ?u32 = 5;
    if (maybe) |value| {
        try expect(value == 5);
    } else {
        unreachable;
    }
}

test "capture an error union" {
    const result: anyerror!u32 = 7;
    if (result) |value| {
        try expect(value == 7);
    } else |_| {
        unreachable;
    }
}

test "capture a union payload in switch" {
    const s = Shape{ .rect = .{ .w = 2, .h = 3 } };
    const area = switch (s) {
        .circle => |r| 3.14 * r * r,
        .rect => |r| r.w * r.h,
    };
    try expect(area == 6);
}

test "capture by pointer to mutate" {
    var maybe: ?u32 = 5;
    if (maybe) |*value| {
        value.* += 1;
    }
    try expect(maybe.? == 6);
}

test "while captures until null" {
    // A `while` over an optional-returning expression loops until null.
    var countdown: u32 = 3;
    var seen: u32 = 0;
    while (nextValue(&countdown)) |value| {
        seen += value;
    }
    try expect(seen == 6); // 3 + 2 + 1
}

fn nextValue(state: *u32) ?u32 {
    if (state.* == 0) return null;
    defer state.* -= 1;
    return state.*;
}
