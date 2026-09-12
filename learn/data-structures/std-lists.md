# The Lists in std Are Intrusive

> std.SinglyLinkedList is not generic and does not hold your data. You embed its node in your struct and walk back out with @fieldParentPtr.

If you have read a Zig tutorial about linked lists, it almost certainly showed
this:

```zig
// Does not compile on current Zig.
var list = std.SinglyLinkedList(i32){};
var node = std.SinglyLinkedList(i32).Node{ .data = 5 };
list.prepend(&node);
```

`std.SinglyLinkedList` is no longer a type function and its nodes no longer
carry a payload. On current master it is a plain type, and its node holds
nothing but a `next` pointer:

```zig
var list: std.SinglyLinkedList = .{};
```

```zig
const std = @import("std");

/// The list node lives *inside* the thing being listed. That is what intrusive
/// means: the container does not wrap your value, your value contains the
/// container's bookkeeping.
const Task = struct {
    name: []const u8,
    priority: u8,
    node: std.SinglyLinkedList.Node = .{},

    /// Given a pointer to the embedded node, recover the struct it sits in.
    ///
    /// `@fieldParentPtr` subtracts the field's offset from the pointer. It is
    /// checked at compile time: the field name must exist on the result type
    /// and have the pointee's type, so the one dangerous-looking line in this
    /// file cannot silently point at the wrong thing.
    fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
        return @fieldParentPtr("node", node);
    }
};

/// A doubly linked version, to show the same shape with a second list type.
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

    // The tasks live wherever you put them. Here that is the stack, and the
    // list allocates nothing at all: no allocator is passed, and `prepend`
    // cannot fail. That is the whole reason the intrusive design exists.
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

    // Removal takes the node, and the node is reachable from the task, so
    // "remove this task" needs no search at all. On the hand-written list two
    // chapters ago the same operation was a walk from the head.
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

    // A node is two words at most and carries no payload, so the cost of being
    // listable is fixed and visible in the struct that pays it. Counted in
    // pointer widths, so the numbers are the same as wasm32 and as a 64-bit
    // native build.
    try out.print("\nsizes in pointer widths\n", .{});
    try out.print("  SinglyLinkedList.Node = {d}\n", .{@sizeOf(std.SinglyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  DoublyLinkedList.Node = {d}\n", .{@sizeOf(std.DoublyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  Task                  = {d} (a slice, a byte, and the node, padded)\n", .{@sizeOf(Task) / @sizeOf(usize)});

    // A task can be on more than one list at a time by holding more than one
    // node. A wrapping list cannot express that without allocating a second
    // node per membership.
    try out.print("\nlists are types, not type functions: {s}, {s}\n", .{
        @typeName(std.SinglyLinkedList), @typeName(std.DoublyLinkedList),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.std-lists`)*

## The node goes inside your struct

```zig
const Task = struct {
    name: []const u8,
    priority: u8,
    node: std.SinglyLinkedList.Node = .{},
};
```

That is what intrusive means. The container does not wrap your value; your
value contains the container's bookkeeping. The list then holds pointers to
those embedded nodes, and to get from a node back to the task it lives in:

```zig
fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
    return @fieldParentPtr("node", node);
}
```

`@fieldParentPtr` subtracts the field's offset from the pointer. It looks
dangerous and is checked at compile time. The named field must exist on the
result type and its type must match the pointer's, so this cannot silently
produce a pointer to the wrong thing. The one thing it does not check is that
the node really is inside that struct. That is why the conversion is written
once, next to the struct that owns it.

## Why std made this trade

The advantages are not aesthetic.

**The list never allocates.** In the snippet the tasks live on the stack and the
list is built with no allocator anywhere. `prepend` cannot fail, so it returns
`void` rather than `!void`. For an allocator's own free list, or a scheduler's
run queue, "insertion cannot fail" is a requirement rather than a convenience.
Those are the places you cannot allocate, because they are what allocation is
built out of.

**Removal needs no search.** `list.remove(&verify.node)` is O(1), because the
node is reachable from the task. The hand-written list two chapters ago had to
walk from the head to find the node holding a value.

**One value, several lists.** A `Task` can hold two node fields and be on two
lists at once. A wrapping list cannot express that without allocating a
separate node per membership.

**The cost is visible.** The node is a field in your struct, so the memory a
membership costs is written down where you can see it, in the type that pays
it.

The price is that the value has to know it might be listed, which is a real
coupling, and that a list of `i32` now needs a wrapper struct.

## Sizes

```
sizes in pointer widths
  SinglyLinkedList.Node = 1
  DoublyLinkedList.Node = 2
  Task                  = 4
```

One pointer for a forward link, two for forward and back. Sizes are printed in
pointer widths because this page runs two ways. As wasm32 in your browser a
pointer is four bytes; natively on your machine it is eight. The relationships
hold either way.

## What to use instead for ordinary work

For "a growable sequence of values",
[ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/). It is contiguous,
cache-friendly, and it is what `std` expects you to reach for.

The intrusive lists are there for the cases in the previous chapter's last
section: pointer stability, O(1) splicing, and insertion that must not
allocate. If you are writing an allocator, a scheduler, or an object pool,
they are exactly right. If you are collecting user records, they are not.

## The migration, if you have old code

- `std.SinglyLinkedList(T)` becomes `std.SinglyLinkedList`, with a `node` field
  added to whatever `T` was.
- `node.data` becomes `@fieldParentPtr("node", node).<your field>`.
- `list.prepend(node)` no longer allocates, so wherever the old code allocated a
  node, allocate your own struct instead and pass `&value.node`.
- `std.DoublyLinkedList` changed the same way, and still gives you `first`,
  `last`, `prev` and `next` for iteration in both directions.
