//! title: Testing
//! The assertions past expect, and what the test allocator checks for you.

const std = @import("std");

test "expectEqual prints both values on failure" {
    // expect(a == b) only tells you "false". expectEqual tells you
    // expected 42, found 41. The expected value comes first.
    try std.testing.expectEqual(42, 41 + 1);
    try std.testing.expectEqual(@as(?u8, null), null);
}

test "slice and string comparisons show where they diverge" {
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &.{ 1, 2, 3 });

    // On failure this prints both strings and the first differing index.
    try std.testing.expectEqualStrings("hello", "hel" ++ "lo");

    try std.testing.expectStringStartsWith("zig build verify", "zig build");
}

fn parseDigit(c: u8) !u4 {
    if (c < '0' or c > '9') return error.NotADigit;
    return @intCast(c - '0');
}

test "expectError asserts the failure path" {
    // Untested error paths rot. This makes them first-class assertions.
    try std.testing.expectError(error.NotADigit, parseDigit('x'));
    try std.testing.expectEqual(7, try parseDigit('7'));
}

test "floats compare within a tolerance" {
    const third: f64 = 1.0 / 3.0;
    // Never == on computed floats; state how close is close enough.
    try std.testing.expectApproxEqAbs(0.333, third, 0.001);
    try std.testing.expectApproxEqRel(1.0, third * 3.0, std.math.floatEps(f64));
}

const Config = struct {
    name: []const u8,
    retries: u8,
};

test "expectEqualDeep follows pointers and slices" {
    const a = Config{ .name = "prod", .retries = 3 };
    const b = Config{ .name = "prod", .retries = 3 };

    // expectEqual on these would compare the slice pointers.
    // expectEqualDeep compares what they point at.
    try std.testing.expectEqualDeep(a, b);
}

test "expectFmt checks formatted output" {
    try std.testing.expectFmt("0x00ff", "0x{x:0>4}", .{255});
}

test "the test allocator reports leaks" {
    // std.testing.allocator fails the test if anything is still
    // allocated when the test returns. Forget this free and the test
    // fails with a stack trace of the leaked allocation.
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 64);
    defer gpa.free(buf);

    // It also detects double-free and use-after-free in test builds.
    try std.testing.expect(buf.len == 64);
}
