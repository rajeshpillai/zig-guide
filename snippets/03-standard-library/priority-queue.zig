//! title: PriorityQueue
//! A binary heap. pop always returns the best element, never the newest.

const std = @import("std");
const expect = std.testing.expect;
const Order = std.math.Order;

fn ascU32(_: void, a: u32, b: u32) Order {
    return std.math.order(a, b);
}

test "min-heap: pop returns the smallest" {
    const gpa = std.testing.allocator;

    // The comparator is part of the type. Order.lt means "a pops first".
    var pq: std.PriorityQueue(u32, void, ascU32) = .empty;
    defer pq.deinit(gpa);

    try pq.push(gpa, 30);
    try pq.push(gpa, 10);
    try pq.push(gpa, 20);

    try expect(pq.peek().? == 10); // look without removing
    try expect(pq.pop().? == 10);
    try expect(pq.pop().? == 20);
    try expect(pq.pop().? == 30);
    try expect(pq.pop() == null);
}

const Job = struct {
    priority: u8,
    name: []const u8,
};

fn urgentFirst(_: void, a: Job, b: Job) Order {
    // Reverse the comparison to get a max-heap.
    return std.math.order(b.priority, a.priority);
}

test "structs with a priority field" {
    const gpa = std.testing.allocator;

    var jobs: std.PriorityQueue(Job, void, urgentFirst) = .empty;
    defer jobs.deinit(gpa);

    try jobs.pushSlice(gpa, &.{
        .{ .priority = 1, .name = "compact logs" },
        .{ .priority = 9, .name = "page the human" },
        .{ .priority = 5, .name = "rebuild index" },
    });

    try expect(std.mem.eql(u8, jobs.pop().?.name, "page the human"));
    try expect(std.mem.eql(u8, jobs.pop().?.name, "rebuild index"));
    try expect(jobs.count() == 1);
}

test "iteration order is not sorted order" {
    const gpa = std.testing.allocator;

    var pq: std.PriorityQueue(u32, void, ascU32) = .empty;
    defer pq.deinit(gpa);
    try pq.pushSlice(gpa, &.{ 5, 1, 4, 2, 3 });

    // The backing array is a heap, not a sorted list. Only pop is ordered.
    var sum: u32 = 0;
    var it = pq.iterator();
    while (it.next()) |v| sum += v;
    try expect(sum == 15);
    try expect(pq.pop().? == 1);
}
