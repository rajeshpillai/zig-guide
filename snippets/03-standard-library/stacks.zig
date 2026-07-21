//! title: Stacks
//! An ArrayList used from one end, plus the linked-list option.

const std = @import("std");
const expect = std.testing.expect;

test "ArrayList is the stack you want" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, 1);
    try stack.append(gpa, 2);
    try stack.append(gpa, 3);

    try expect(stack.pop().? == 3);
    try expect(stack.getLast() == 2);
    try expect(stack.items.len == 2);
}

test "pop returns null when empty" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(gpa);

    try expect(stack.pop() == null);
}

test "a bounded stack needs no allocator at all" {
    // For a known maximum, a fixed buffer avoids the heap entirely.
    var buffer: [8]u32 = undefined;
    var len: usize = 0;

    for ([_]u32{ 10, 20, 30 }) |v| {
        buffer[len] = v;
        len += 1;
    }
    len -= 1;
    try expect(buffer[len] == 30);
}

test "balanced bracket check" {
    const gpa = std.testing.allocator;
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(gpa);

    const input = "([]{})";
    var balanced = true;
    for (input) |c| switch (c) {
        '(', '[', '{' => try stack.append(gpa, c),
        ')' => balanced = balanced and stack.pop() == '(',
        ']' => balanced = balanced and stack.pop() == '[',
        '}' => balanced = balanced and stack.pop() == '{',
        else => {},
    };
    try expect(balanced and stack.items.len == 0);
}
