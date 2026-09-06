# PriorityQueue

> A binary heap where the comparator is part of the type.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.priority-queue`)*

## The comparator lives in the type

`std.PriorityQueue(T, Context, compareFn)` bakes the ordering into the type
itself, the same shape `std.sort` uses. The function returns a
`std.math.Order`: return `.lt` when the first argument should pop before the
second. So the comparator reads like "which comes first," and swapping its two
arguments turns a min-heap into a max-heap.

The `Context` parameter is `void` when the comparison needs nothing external.
Give it a real type to compare against runtime data, for example distances
against a target you only know at run time; pass the value through
`initContext`.

Putting the comparator in the type rather than in a field is what makes every
comparison a direct call the optimiser can inline. It also means two queues
with different orderings are different types, so one cannot be passed where
the other is expected.

## It is unmanaged, like the rest

```zig
var q: std.PriorityQueue(u32, void, ascU32) = .empty;
defer q.deinit(gpa);

try q.push(gpa, 30);
const smallest = q.pop();     // ?u32
```

`.empty` to create, allocator to every method that can allocate, and `pop`
returns an optional so the empty case is in the type. If you find code calling
`init(allocator, {})` with `add` and `removeOrNull`, that is the older managed
shape. The methods are `push` and `pop` now, and the allocator is passed per
call.

`pushSlice` adds several at once, and `count` and `capacity` report the
obvious things. `update(old, new)` replaces an element and restores the heap
order, which is what a Dijkstra implementation needs when it finds a shorter
path to a node already in the queue.

## What it is good at

`push` and `pop` are O(log n); `peek` is O(1). Use it when you repeatedly need
the current best element out of a changing set. A scheduler pulling the most
urgent job. Dijkstra pulling the nearest node. A merge of sorted streams.

The shape to look for is interleaving. If everything is added and then
everything is removed, sorting once is faster and simpler. The heap wins when
pushes and pops are mixed, because it never pays to fully order the elements
it has not reached yet.

It is also the right structure for "the largest k of n" when n is large. Push
everything and keep the heap capped at k. You have then used memory
proportional to k, rather than sorting n items to throw most of them away.

## What it is not

The backing storage is a heap, not a sorted array. `iterator` walks that
storage in heap order, which is not sorted order. Only `pop` gives you
elements in priority sequence. If you need everything sorted once, an
`ArrayList` plus `std.sort` is the better fit; the queue is worth using when
insertions and removals are interleaved.

It is also not stable. Two elements the comparator calls equal come out in
whatever order the heap produces, and that order can change when unrelated
elements are inserted. When ties need to break by insertion time, put a
sequence number in the element and compare it as a second key.

Nor is it a queue in the FIFO sense, despite the name. If what you want is
"first in, first out", that is a [queue](https://www.ziglang.in/learn/standard-library/queues/) and
it is O(1) rather than O(log n).
