//! title: ArrayList
//! A growable array. Since 0.15 it is unmanaged: pass the allocator in.

const std = @import("std");
const expect = std.testing.expect;

test "build up a list" {
    const gpa = std.testing.allocator;

    // `.empty` replaces `init(allocator)`. The list does not store the
    // allocator, so every method that may allocate takes one.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.append(gpa, 'h');
    try list.appendSlice(gpa, "ello");

    try expect(std.mem.eql(u8, list.items, "hello"));
    try expect(list.items.len == 5);
}

test "items is a plain slice" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    for (0..5) |i| try list.append(gpa, @intCast(i * i));

    // `.items` is a `[]T` into the list's buffer, valid until the next
    // reallocation, so do not hold it across an append.
    try expect(list.items[4] == 16);
}

test "pop and remove" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "abcd");
    try expect(list.pop().? == 'd');
    _ = list.orderedRemove(0); // shifts the rest down
    try expect(std.mem.eql(u8, list.items, "bc"));
}

test "preallocate when the size is known" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    // One allocation instead of a growth sequence.
    try list.ensureTotalCapacity(gpa, 100);
    for (0..100) |_| list.appendAssumeCapacity('x');
    try expect(list.items.len == 100);
}

test "take ownership of the buffer" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, "owned");

    // `toOwnedSlice` hands you the memory and empties the list, so the
    // caller frees the slice rather than deinit-ing the list.
    const slice = try list.toOwnedSlice(gpa);
    defer gpa.free(slice);
    try expect(std.mem.eql(u8, slice, "owned"));
}
