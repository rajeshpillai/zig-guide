//! title: ArrayList
//! An array that can grow. From 0.15, it is unmanaged: give it the allocator.

const std = @import("std");
const expect = std.testing.expect;

test "build up a list" {
    const gpa = std.testing.allocator;

    // `.empty` replaces `init(allocator)`. The list does not store the
    // allocator. Thus each method that can allocate takes an allocator.
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

    // `.items` is a `[]T` into the buffer of the list. It is valid until
    // the next reallocation. Thus do not keep it across an append.
    try expect(list.items[4] == 16);
}

test "pop and remove" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, "abcd");
    try expect(list.pop().? == 'd');
    _ = list.orderedRemove(0); // moves the other items down
    try expect(std.mem.eql(u8, list.items, "bc"));
}

test "preallocate when the size is known" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);

    // One allocation, not a series of growth steps.
    try list.ensureTotalCapacity(gpa, 100);
    for (0..100) |_| list.appendAssumeCapacity('x');
    try expect(list.items.len == 100);
}

test "take ownership of the buffer" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(gpa, "owned");

    // `toOwnedSlice` gives you the memory and makes the list empty. Thus
    // the caller frees the slice, and does not call deinit on the list.
    const slice = try list.toOwnedSlice(gpa);
    defer gpa.free(slice);
    try expect(std.mem.eql(u8, slice, "owned"));
}

test "lock the buffer in place while holding a pointer into it" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    try list.appendSlice(gpa, &.{ 1, 2, 3 });

    // Between these two calls, the buffer must not move. Thus a pointer into
    // the buffer stays valid. In a safety build, an operation that
    // reallocates panics. It does not make `first` invalid without a report.
    list.lockPointers();
    const first = &list.items[0];
    first.* += 10;
    list.unlockPointers();

    try expect(list.items[0] == 11);
}
