# A Binary Search Tree

> Two pointers instead of one give ordered iteration and O(log n) lookup, on a condition that the structure does not enforce.

Give the node a second pointer. Keep all smaller values on the left and all larger values on the right. Then each step of a lookup removes half of the search space. An in-order walk visits the values in sorted order, with no extra work.

These two advantages are true only while the tree stays approximately balanced. Nothing in the insert code keeps the tree balanced.

```zig
const std = @import("std");

const Tree = struct {
    root: ?*Node = null,
    len: usize = 0,
    allocator: std.mem.Allocator,

    const Node = struct {
        value: i32,
        left: ?*Node = null,
        right: ?*Node = null,
    };

    fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    /// Post-order, because no other order is correct. If you free a node
    /// before its children, you cannot get to the children. The compiler
    /// cannot find that leak, but the allocator in `main` checks for leaks.
    fn deinit(self: *Tree) void {
        freeSubtree(self.allocator, self.root);
        self.root = null;
        self.len = 0;
    }

    fn freeSubtree(allocator: std.mem.Allocator, maybe: ?*Node) void {
        const node = maybe orelse return;
        freeSubtree(allocator, node.left);
        freeSubtree(allocator, node.right);
        allocator.destroy(node);
    }

    /// Insert, with a loop.
    ///
    /// The recursive version is easier to read, and most textbooks show it.
    /// This version is a loop over a pointer to a pointer. `link` points at
    /// the slot for the new node. Thus the null case and the ordinary case
    /// use the same code. An empty tree needs no special case.
    fn insert(self: *Tree, value: i32) !void {
        var link: *?*Node = &self.root;
        while (link.*) |node| {
            if (value == node.value) return; // set semantics: no duplicates
            link = if (value < node.value) &node.left else &node.right;
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .value = value };
        link.* = node;
        self.len += 1;
    }

    fn contains(self: *const Tree, value: i32) bool {
        var current = self.root;
        while (current) |node| {
            if (value == node.value) return true;
            current = if (value < node.value) node.left else node.right;
        }
        return false;
    }

    /// Left, self, right. This visits the values in sorted order. When order
    /// is important, sorted order is the reason to use a tree instead of a
    /// hash table.
    fn writeInOrder(self: *const Tree, out: *std.Io.Writer) !void {
        try walk(out, self.root);
        try out.writeByte('\n');
    }

    fn walk(out: *std.Io.Writer, maybe: ?*Node) !void {
        const node = maybe orelse return;
        try walk(out, node.left);
        try out.print("{d} ", .{node.value});
        try walk(out, node.right);
    }

    /// The longest path from the root to a leaf. This number decides if
    /// lookup is fast, and nothing in `insert` controls it.
    fn height(self: *const Tree) usize {
        return subtreeHeight(self.root);
    }

    fn subtreeHeight(maybe: ?*Node) usize {
        const node = maybe orelse return 0;
        return 1 + @max(subtreeHeight(node.left), subtreeHeight(node.right));
    }
};

fn buildFrom(allocator: std.mem.Allocator, values: []const i32) !Tree {
    var tree = Tree.init(allocator);
    for (values) |v| try tree.insert(v);
    return tree;
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    var tree = try buildFrom(allocator, &.{ 50, 30, 70, 20, 40, 60, 80 });
    defer tree.deinit();

    try out.writeAll("in-order:  ");
    try tree.writeInOrder(out);
    try out.print("contains(40) -> {}\n", .{tree.contains(40)});
    try out.print("contains(45) -> {}\n", .{tree.contains(45)});
    try out.print("len {d}, height {d}\n", .{ tree.len, tree.height() });

    // The order of insertion decides the shape. The shape decides all the
    // other properties. A tree from sorted input never branches: each value
    // is larger than the previous value, so each value goes to the right.
    var sorted_values: [15]i32 = undefined;
    for (&sorted_values, 1..) |*v, i| v.* = @intCast(i);

    var balanced_values = [_]i32{ 8, 4, 12, 2, 6, 10, 14, 1, 3, 5, 7, 9, 11, 13, 15 };

    var degenerate = try buildFrom(allocator, &sorted_values);
    defer degenerate.deinit();
    var balanced = try buildFrom(allocator, &balanced_values);
    defer balanced.deinit();

    try out.writeAll("\nsame 15 values, two insertion orders\n");
    try out.print("  sorted input:   height {d:>2}  (a linked list wearing a tree's type)\n", .{degenerate.height()});
    try out.print("  balanced input: height {d:>2}\n", .{balanced.height()});
    try out.print("  ideal for 15 nodes: {d}\n", .{std.math.log2_int(usize, 15) + 1});

    // Both still iterate in order. The invariant holds. Only the cost changed.
    try out.writeAll("\ndegenerate tree, in-order: ");
    try degenerate.writeInOrder(out);

    // Count the comparisons to find the largest value, and print the count.
    try out.print("\nlookups to find 15:\n", .{});
    try out.print("  degenerate tree: {d} comparisons\n", .{countSteps(&degenerate, 15)});
    try out.print("  balanced tree:   {d} comparisons\n", .{countSteps(&balanced, 15)});

    try out.flush();
}

fn countSteps(tree: *const Tree, value: i32) usize {
    var steps: usize = 0;
    var current = tree.root;
    while (current) |node| {
        steps += 1;
        if (value == node.value) return steps;
        current = if (value < node.value) node.left else node.right;
    }
    return steps;
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.bst`)*

## Insert through a pointer to a pointer

Textbooks usually show a recursive version. This version is a loop:

```zig
var link: *?*Node = &self.root;
while (link.*) |node| {
    if (value == node.value) return;
    link = if (value < node.value) &node.left else &node.right;
}

const node = try self.allocator.create(Node);
node.* = .{ .value = value };
link.* = node;
```

`link` points at the slot that will hold the new node. It does not point at the node above that slot. An insert into an empty tree writes through `&self.root`. An insert at a leaf writes through `&node.left`. The two cases use the same two lines. Thus the empty tree needs no special case, and the code needs no "was this the root" branch.

Read `*?*Node` slowly: a pointer, to an optional, to a node. Each layer has a function. The optional is the empty slot. The outer pointer lets you write into that slot.

## The deinit must be post-order

```zig
fn freeSubtree(allocator: std.mem.Allocator, maybe: ?*Node) void {
    const node = maybe orelse return;
    freeSubtree(allocator, node.left);
    freeSubtree(allocator, node.right);
    allocator.destroy(node);
}
```

Free the children first, then the node. If you free the node first, you lose the only pointers to its subtrees. The result is a leak of unreachable memory, not a crash. The snippet uses an allocator that checks for leaks. Thus the allocator enforces the order, and you do not have to remember it.

The height of the tree is the limit for the depth of this recursion. The next section is about that height. On a degenerate tree of a million nodes, the recursion overflows the stack. For this reason, production code for trees often keeps an explicit stack.

## The order of insertion decides the shape

The program inserts the same fifteen values in two different orders:

```
  sorted input:   height 15  (a linked list wearing a tree's type)
  balanced input: height  4
  ideal for 15 nodes: 4
```

A tree from sorted input never branches. Each value is larger than the previous value, so each value goes to the right. The result is a linked list with an unused `left` pointer in each node. The search property is still true, and an in-order traversal still prints the values in order. Only the cost changed:

```
lookups to find 15:
  degenerate tree: 15 comparisons
  balanced tree:   4 comparisons
```

An unbalanced binary search tree fails at exactly this point, and sorted input is not an unusual case. You get sorted input from a database export, a sorted file, a monotonic ID, or a timestamp. These inputs are the most likely in production. They are the least likely in a test with literal values that a person selected by hand.

## What the standard library gives you

`std` has no general-purpose balanced tree. You have these options:

- **[Hash maps](https://www.ziglang.in/learn/standard-library/hash-maps/)**, when you need lookup and not order. A hash map is faster than all trees for lookup, and most code needs only lookup.
- **Sort an ArrayList and do a binary search on it**, when you build the data one time and query it many times. The array is contiguous and cache-friendly. It is better than a tree for all uses, except inserts and lookups that alternate.
- **[PriorityQueue](https://www.ziglang.in/learn/standard-library/priority-queue/)**, when you need only the smallest element. That is a heap, which is a different structure.
- **`std.Treap`**, which is already in `std`. A treap uses probability to keep itself balanced, not rotations.

One case remains: you need ordered iteration, and inserts and lookups alternate. For that case, the tree must repair its own shape. The next chapter adds this repair to the tree.
