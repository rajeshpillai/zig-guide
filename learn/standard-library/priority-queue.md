# PriorityQueue

> A binary heap where the comparator is part of the type.

`std.PriorityQueue(T, Context, compareFn)` is the binary heap in Zig. `push` and `pop` are O(log n). `pop` returns the element that the comparator puts first, or `null` when the queue is empty.

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

    try expect(pq.peek().? == 10); // read the top value, but do not remove it
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
    // Reverse the comparison to make a max-heap.
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

    // The storage array is a heap, not a sorted list. Only pop gives an order.
    var sum: u32 = 0;
    var it = pq.iterator();
    while (it.next()) |v| sum += v;
    try expect(sum == 15);
    try expect(pq.pop().? == 1);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.priority-queue`)*

## The comparator is part of the type

`std.PriorityQueue(T, Context, compareFn)` puts the order into the type. `std.sort` uses the same shape. The function returns a `std.math.Order`. Return `.lt` when the first argument must pop before the second argument.

Thus the comparator answers the question "which comes first". If you swap its two arguments, a min-heap becomes a max-heap.

The `Context` parameter is `void` when the comparison needs no external data. To compare against runtime data, give the parameter a real type. An example is distances to a target that you know only at runtime. Give the value to the queue through `initContext`.

The comparator is in the type and not in a field. Thus each comparison is a direct call that the optimiser can inline. Also, two queues with different orders are different types. You cannot use one of them where the code expects the other.

## It is unmanaged, as the other containers are

```zig
var q: std.PriorityQueue(u32, void, ascU32) = .empty;
defer q.deinit(gpa);

try q.push(gpa, 30);
const smallest = q.pop();     // ?u32
```

The rules are the same as for the other containers:

- Use `.empty` to create the queue.
- Give the allocator to each method that can allocate.
- `pop` returns an optional, thus the empty case is in the type.

Older code calls `init(allocator, {})` and uses `add` and `removeOrNull`. That is the older managed shape. Now the methods are `push` and `pop`, and you give the allocator to each call.

`pushSlice` adds several elements in one call. `count` gives the number of elements, and `capacity` gives the size of the storage. `update(old, new)` replaces an element and makes the heap order correct again. A Dijkstra implementation needs `update` when it finds a shorter path to a node that is already in the queue.

## When to use it

`push` and `pop` are O(log n), and `peek` is O(1). Use the queue when you must get the current best element from a set that changes again and again. Examples:

- A scheduler gets the most urgent job.
- Dijkstra gets the nearest node.
- A merge of sorted streams gets the next value.

Look for pushes and pops that occur in a mixed sequence. If the code adds all the elements and then removes all of them, one sort is faster and simpler. The heap is better when the code mixes pushes and pops. It never spends work to put the elements in full order before it must use them.

The heap is also the correct structure for "the largest k of n" when n is large. Push all the items, and keep the heap at a maximum size of k. Then the memory that you use is proportional to k. You do not sort n items and then discard most of them.

## What it is not

The storage is a heap, not a sorted array. `iterator` walks that storage in heap order, and heap order is not sorted order. Only `pop` gives you the elements in priority order.

If you must sort all the elements one time, an `ArrayList` and `std.sort` are a better choice. Use the queue when the code mixes insertions and removals.

The queue is also not stable. Two elements that the comparator calls equal come out in the order that the heap gives. That order can change when you insert other elements. If ties must break by the time of insertion, put a sequence number in the element. Compare the sequence number as a second key.

The name has the word "queue", but it is not a FIFO queue. If you want "first in, first out", use a [queue](https://www.ziglang.in/learn/concurrency/queues/). A queue is O(1) and not O(log n).
