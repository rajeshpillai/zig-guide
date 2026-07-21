//! title: Running Tests
//! `test` blocks are part of the language, not a framework.

const std = @import("std");
const expect = std.testing.expect;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "a test is just a named block" {
    try expect(add(2, 2) == 4);
}

test "expectEqual reports both values on failure" {
    try std.testing.expectEqual(@as(i32, 4), add(2, 2));
}

test "comparing slices" {
    try std.testing.expectEqualStrings("abc", "ab" ++ "c");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2 }, &[_]u8{ 1, 2 });
}

test "asserting an error is returned" {
    const failing = struct {
        fn f() error{Nope}!void {
            return error.Nope;
        }
    }.f;
    try std.testing.expectError(error.Nope, failing());
}

test "the testing allocator fails the test on a leak" {
    const gpa = std.testing.allocator;
    const buf = try gpa.alloc(u8, 10);
    defer gpa.free(buf); // remove this line and the test fails
    try expect(buf.len == 10);
}

test "skipping" {
    if (@import("builtin").cpu.arch != .wasm32) return error.SkipZigTest;
    try expect(true);
}
