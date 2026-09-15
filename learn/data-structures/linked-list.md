# A Linked List by Hand

> The smallest structure that needs an allocator, an optional pointer and a deinit that gets the order right.

A linked list is a poor container. It scatters its elements across memory, so
walking one is a chain of dependent loads that the prefetcher cannot help
with. An `ArrayList` beats it at almost everything you would use a list for.

It is still the right first structure to build. It is the smallest one that
forces you to answer the three questions every container in Zig has to answer.
Who allocates. What "no next element" looks like in the type system. And who
frees.

```zig
const std = @import("std");

const Node = struct {
    value: i32,
    /// `?*Node`, not `*?Node`. This is an optional pointer to a node: it is
    /// either null or the address of a node. `*?Node` would be a pointer to a
    /// slot that might hold a node, which is a different thing and needs the
    /// slot to exist somewhere.
    next: ?*Node = null,
};

const List = struct {
    head: ?*Node = null,
    /// Kept so `append` is O(1). Without it, appending to a list of n items
    /// walks all n, and building a list of n items becomes O(n^2).
    tail: ?*Node = null,
    len: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    /// The list owns every node it allocates, so it is the list that frees
    /// them. Walking and freeing has one ordering rule and it is easy to get
    /// wrong: read `next` *before* destroying the node it lives in.
    fn deinit(self: *List) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next; // read first
            self.allocator.destroy(node); // then free
            current = next;
        }
        self.head = null;
        self.tail = null;
        self.len = 0;
    }

    fn append(self: *List, value: i32) !void {
        const node = try self.allocator.create(Node);
        node.* = .{ .value = value };

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.len += 1;
    }

    fn prepend(self: *List, value: i32) !void {
        const node = try self.allocator.create(Node);
        node.* = .{ .value = value, .next = self.head };

        self.head = node;
        if (self.tail == null) self.tail = node;
        self.len += 1;
    }

    fn find(self: *const List, value: i32) ?*Node {
        var current = self.head;
        while (current) |node| : (current = node.next) {
            if (node.value == value) return node;
        }
        return null;
    }

    /// Remove the first node holding `value`.
    ///
    /// The awkward part of a singly linked list: unlinking a node needs the
    /// node *before* it, which cannot be reached from the node itself. Tracking
    /// `previous` through the walk is the usual answer, and the special case
    /// for the head is the price.
    fn remove(self: *List, value: i32) bool {
        var previous: ?*Node = null;
        var current = self.head;

        while (current) |node| {
            if (node.value == value) {
                if (previous) |prev| {
                    prev.next = node.next;
                } else {
                    self.head = node.next;
                }
                if (self.tail == node) self.tail = previous;
                self.allocator.destroy(node);
                self.len -= 1;
                return true;
            }
            previous = node;
            current = node.next;
        }
        return false;
    }

    fn write(self: *const List, out: *std.Io.Writer) !void {
        var current = self.head;
        try out.writeAll("[");
        while (current) |node| : (current = node.next) {
            try out.print("{d}", .{node.value});
            if (node.next != null) try out.writeAll(" -> ");
        }
        try out.print("] len={d}\n", .{self.len});
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // A leak-checking allocator, because a container that hands out memory is
    // exactly where a leak comes from. `deinit` reports `.leak` if anything
    // this program allocated was not freed.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    var list = List.init(allocator);
    defer list.deinit();

    for ([_]i32{ 10, 20, 30 }) |v| try list.append(v);
    try list.prepend(5);
    try list.write(out);

    try out.print("find(20)  -> {?d}\n", .{if (list.find(20)) |n| n.value else null});
    try out.print("find(99)  -> {?d}\n", .{if (list.find(99)) |n| n.value else null});

    _ = list.remove(20);
    try out.writeAll("after remove(20): ");
    try list.write(out);

    _ = list.remove(5); // the head
    try out.writeAll("after remove(5):  ");
    try list.write(out);

    _ = list.remove(30); // the tail
    try out.writeAll("after remove(30): ");
    try list.write(out);

    // An optional pointer costs nothing. Zig knows a pointer can never validly
    // be zero, so it uses zero as the null tag rather than adding a flag
    // beside it. This is why `?*T` is the idiomatic way to express "maybe a
    // node" and why a hand-rolled sentinel buys nothing.
    //
    // Sizes are printed in pointer widths rather than bytes, so the answers are
    // the same whether this runs as wasm32 in your browser or natively on a
    // 64-bit machine. The relationships are the point; the byte counts are the
    // target's business.
    try out.print("\n@sizeOf(?*Node) == @sizeOf(*Node) -> {}\n", .{@sizeOf(?*Node) == @sizeOf(*Node)});
    try out.print("@sizeOf(?i32)    > @sizeOf(i32)    -> {} (an integer has no spare value to mean null)\n", .{@sizeOf(?i32) > @sizeOf(i32)});
    try out.print("@sizeOf(Node) in pointers = {d}\n", .{@sizeOf(Node) / @sizeOf(usize)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.linked-list`)*

## `?*Node`, not `*?Node`

```zig
const Node = struct {
    value: i32,
    next: ?*Node = null,
};
```

`?*Node` is an optional pointer: either null, or the address of a node.
`*?Node` would be a pointer to a slot that may contain a node, which needs the
slot to exist somewhere and is a different structure entirely. The order reads
outside in, and getting it backwards is the most common early mistake with
linked structures.

The optional is free:

```
@sizeOf(?*Node) == @sizeOf(*Node) -> true
@sizeOf(?i32)    > @sizeOf(i32)   -> true
```

A pointer can never validly be zero, so Zig uses zero as the null
representation rather than storing a flag beside it. An optional integer has
no spare value to use that way, so it does grow. This is why `?*T` is the
idiomatic way to say "maybe a node" and why inventing a sentinel value buys
nothing.

## The deinit has an ordering rule

```zig
var current = self.head;
while (current) |node| {
    const next = node.next;        // read first
    self.allocator.destroy(node);  // then free
    current = next;
}
```

Reading `node.next` after destroying `node` is a use-after-free. It usually
appears to work, because the allocator has not yet handed that memory to
anyone else, which is what makes it a bug that ships.

The snippet runs under `std.heap.SafeAllocator` (`DebugAllocator` in older
code), whose `deinit` returns the number of allocations that were never freed.
A container that hands out memory is exactly where a leak comes from, so it is
worth having the allocator check rather than reasoning about it. [Catching
Memory Leaks](https://www.ziglang.in/learn/how-to/catching-leaks/) covers the tooling.

## Two fields that are not obvious

**`tail`** exists so `append` is O(1). Without it, appending walks the whole
list first, and building a list of n items is O(n²). Almost every hand-rolled
list on the internet omits it.

**`len`** is stored rather than counted. Counting is O(n), and a `len()` that
walks the list turns an innocent `if (list.len() > 0)` inside a loop into a
quadratic bug.

Both are the same trade: a few bytes of bookkeeping in exchange for a whole
class of accidental quadratic behaviour.

## Where a singly linked list stops being pleasant

Removal needs the node *before* the one being removed, and you cannot get
there from the node itself. So `remove` tracks `previous` through the walk and
special cases the head:

```zig
if (previous) |prev| {
    prev.next = node.next;
} else {
    self.head = node.next;
}
```

This is the shape that pushes people to a doubly linked list, and then to
wondering why `std`'s lists look nothing like this one. Both are the next two
chapters.

## When a linked list is actually right

Not often, but the cases are real and they are all about pointer stability:

- Elements must not move when the collection grows. An ArrayList reallocates,
  which invalidates every pointer into it; a linked list never moves a node.
- Splicing a whole run from one list into another in O(1), without touching the
  elements.
- Insertion must never fail, or must not allocate at the moment of insertion.
  This is what the intrusive design two chapters from now is for, and it is why
  allocators and schedulers are full of linked lists.

If none of those apply, use an ArrayList.
