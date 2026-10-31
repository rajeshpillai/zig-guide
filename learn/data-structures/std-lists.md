# The Lists in std Are Intrusive

> std.SinglyLinkedList is not generic and does not hold your data. Put its node in your struct and get back to the struct with @fieldParentPtr.

If you read a Zig tutorial about linked lists, the tutorial almost certainly showed this code:

```zig
// Does not compile on current Zig.
var list = std.SinglyLinkedList(i32){};
var node = std.SinglyLinkedList(i32).Node{ .data = 5 };
list.prepend(&node);
```

`std.SinglyLinkedList` is no longer a type function, and its nodes no longer carry a payload. On current master, `std.SinglyLinkedList` is a plain type. Its node holds only a `next` pointer:

```zig
var list: std.SinglyLinkedList = .{};
```

```zig
const std = @import("std");

/// The list node is *inside* the value that is in the list. This is the
/// meaning of intrusive: your value contains the bookkeeping of the container,
/// and the container does not wrap your value.
const Task = struct {
    name: []const u8,
    priority: u8,
    node: std.SinglyLinkedList.Node = .{},

    /// From a pointer to the embedded node, get the struct that contains it.
    ///
    /// `@fieldParentPtr` subtracts the offset of the field from the pointer.
    /// The compiler checks it at compile time. The field name must exist on
    /// the result type, and the field must have the type of the pointee. Thus
    /// this line looks dangerous, but it cannot silently point at the wrong
    /// thing.
    fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
        return @fieldParentPtr("node", node);
    }
};

/// A doubly linked version. It shows the same shape with a second list type.
const Job = struct {
    id: u32,
    node: std.DoublyLinkedList.Node = .{},

    fn fromNode(node: *std.DoublyLinkedList.Node) *Job {
        return @fieldParentPtr("node", node);
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // The tasks are in the location that you select. Here, that location is
    // the stack. The list allocates nothing: the program gives it no
    // allocator, and `prepend` cannot fail. The intrusive design has this
    // purpose.
    var deploy = Task{ .name = "deploy", .priority = 3 };
    var verify = Task{ .name = "verify", .priority = 1 };
    var build = Task{ .name = "build", .priority = 2 };

    var list: std.SinglyLinkedList = .{};
    list.prepend(&deploy.node);
    list.prepend(&verify.node);
    list.prepend(&build.node);

    try out.writeAll("singly linked, walked by node:\n");
    var it = list.first;
    while (it) |node| : (it = node.next) {
        const task = Task.fromNode(node);
        try out.print("  {s} (priority {d})\n", .{ task.name, task.priority });
    }
    try out.print("len = {d}\n", .{list.len()});

    // `remove` takes the node, and you can get to the node from the task.
    // Thus "remove this task" needs no search. On the hand-written list two
    // chapters ago, the same operation was a walk from the head.
    list.remove(&verify.node);
    try out.print("\nafter removing verify, len = {d}\n", .{list.len()});

    var jobs: std.DoublyLinkedList = .{};
    var a = Job{ .id = 1 };
    var b = Job{ .id = 2 };
    var c = Job{ .id = 3 };
    jobs.append(&a.node);
    jobs.append(&b.node);
    jobs.append(&c.node);

    try out.writeAll("\ndoubly linked, forwards:  ");
    var f = jobs.first;
    while (f) |node| : (f = node.next) try out.print("{d} ", .{Job.fromNode(node).id});
    try out.writeAll("\ndoubly linked, backwards: ");
    var r = jobs.last;
    while (r) |node| : (r = node.prev) try out.print("{d} ", .{Job.fromNode(node).id});
    try out.writeByte('\n');

    // A node is two words or less and carries no payload. Thus the cost of a
    // list membership is fixed, and you can see it in the struct that holds
    // the node. The sizes are in pointer widths, so the numbers are the same
    // on wasm32 and on a 64-bit native build.
    try out.print("\nsizes in pointer widths\n", .{});
    try out.print("  SinglyLinkedList.Node = {d}\n", .{@sizeOf(std.SinglyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  DoublyLinkedList.Node = {d}\n", .{@sizeOf(std.DoublyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  Task                  = {d} (a slice, a byte, and the node, padded)\n", .{@sizeOf(Task) / @sizeOf(usize)});

    // A task that holds more than one node can be on more than one list at
    // the same time. A list that wraps values cannot do this unless it
    // allocates a second node for each membership.
    try out.print("\nlists are types, not type functions: {s}, {s}\n", .{
        @typeName(std.SinglyLinkedList), @typeName(std.DoublyLinkedList),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.std-lists`)*

## Put the node inside your struct

```zig
const Task = struct {
    name: []const u8,
    priority: u8,
    node: std.SinglyLinkedList.Node = .{},
};
```

This is the meaning of intrusive. The container does not wrap your value. Your value contains the bookkeeping of the container. The list holds pointers to the nodes inside the tasks. To get from a node to the task that contains it, use this function:

```zig
fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
    return @fieldParentPtr("node", node);
}
```

`@fieldParentPtr` subtracts the offset of the field from the pointer. It looks dangerous, but the compiler checks it at compile time:

- The named field must exist on the result type.
- The type of the field must agree with the type of the pointer.

Thus this function cannot silently make a pointer to the wrong thing. The compiler does not check one thing: that the node is really inside that struct. For this reason, write the conversion one time, next to the struct that owns it.

## Why std made this trade

The advantages are practical.

**The list never allocates.** In the snippet, the tasks are on the stack, and the program builds the list without an allocator. `prepend` cannot fail, so it returns `void`, not `!void`. An allocator has its own free list, and a scheduler has a run queue. For these lists, "insertion cannot fail" is a requirement, not a convenience. You cannot allocate in these places, because allocation itself uses them.

**Removal needs no search.** `list.remove(&verify.node)` is O(1), because you can get to the node from the task. The hand-written list two chapters ago had to walk from the head to find the node with a given value.

**One value can be on many lists.** A `Task` can hold two node fields and be on two lists at the same time. A list that wraps values cannot do this unless it allocates a separate node for each membership.

**The cost is visible.** The node is a field in your struct. Thus you can see the memory cost of a membership in the type that pays it.

The price has two parts. First, the value must know that it can be in a list, and this is a real coupling. Second, a list of `i32` now needs a wrapper struct.

## Sizes

```
sizes in pointer widths
  SinglyLinkedList.Node = 1
  DoublyLinkedList.Node = 2
  Task                  = 4
```

A forward link needs one pointer. A forward link and a back link need two. The sizes are in pointer widths, because this page runs in two ways. As wasm32 in your browser, a pointer is four bytes. Natively on your computer, a pointer is eight bytes. The relations between the sizes are the same in both cases.

## What to use for ordinary work

For "a growable sequence of values", use [ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/). It is contiguous and cache-friendly, and `std` expects you to use it first.

The last section of the linked list chapter, two chapters ago, gives the cases for the intrusive lists. These cases are pointer stability, O(1) splicing, and insertion that must not allocate. For an allocator, a scheduler, or an object pool, they are exactly correct. For a collection of user records, they are not correct.

## Change old code to the new lists

- `std.SinglyLinkedList(T)` becomes `std.SinglyLinkedList`. Add a `node` field to the type that was `T`.
- `node.data` becomes `@fieldParentPtr("node", node).<your field>`.
- `list.prepend(node)` does not allocate now. Where the old code allocated a node, allocate your own struct and give `&value.node` to the list.
- `std.DoublyLinkedList` changed in the same way. It still gives you `first`, `last`, `prev` and `next`, so that you can iterate in the two directions.
