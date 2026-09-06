# Keeping It Balanced

> Store a height, check it after every insert, repair it with a local rotation. Four cases, none longer than five lines.

The previous chapter's tree turns into a linked list on sorted input. An AVL
tree fixes that with three additions: a height stored in each node, a check
after every insert, and a rotation to repair the shape when the check fails.

The result on the exact input that ruined the plain tree:

```
final height 4, ideal 4, rotations 11
balanced everywhere: true
```

Fifteen values inserted in ascending order, and the tree comes out at the
minimum possible height, having done eleven rotations to get there.

```zig
const std = @import("std");

const Tree = struct {
    root: ?*Node = null,
    len: usize = 0,
    allocator: std.mem.Allocator,
    /// Counted so the output can show that balancing is cheap: a handful of
    /// rotations for a whole tree, not one per node.
    rotations: usize = 0,

    const Node = struct {
        value: i32,
        left: ?*Node = null,
        right: ?*Node = null,
        /// A leaf has height 1. Kept in the node rather than recomputed,
        /// because recomputing it is the O(n) walk this structure exists to
        /// avoid.
        height: i32 = 1,
    };

    fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

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

    fn heightOf(maybe: ?*Node) i32 {
        return if (maybe) |node| node.height else 0;
    }

    fn refresh(node: *Node) void {
        node.height = 1 + @max(heightOf(node.left), heightOf(node.right));
    }

    /// Left height minus right height. The invariant is that this stays in
    /// -1..1 for every node in the tree. Two means one side is a full level
    /// deeper than the other, which is the moment to rotate.
    fn balance(maybe: ?*Node) i32 {
        const node = maybe orelse return 0;
        return heightOf(node.left) - heightOf(node.right);
    }

    /// Rotate right: the left child becomes the new root of this subtree.
    ///
    ///       y            x
    ///      / \          / \
    ///     x   C   ->   A   y
    ///    / \              / \
    ///   A   B            B   C
    ///
    /// B changes parent and nothing else moves. In-order it is still A x B y C
    /// both before and after, which is why a rotation preserves the search
    /// property for free.
    fn rotateRight(self: *Tree, y: *Node) *Node {
        const x = y.left.?;
        y.left = x.right;
        x.right = y;
        refresh(y);
        refresh(x);
        self.rotations += 1;
        return x;
    }

    fn rotateLeft(self: *Tree, x: *Node) *Node {
        const y = x.right.?;
        x.right = y.left;
        y.left = x;
        refresh(x);
        refresh(y);
        self.rotations += 1;
        return y;
    }

    fn insert(self: *Tree, value: i32) !void {
        self.root = try self.insertInto(self.root, value);
    }

    /// Recursive, because rebalancing happens on the way back *up*: each node
    /// on the path from the insertion point to the root gets its height
    /// refreshed and its balance checked, and returning the (possibly new)
    /// subtree root is what relinks a rotation into its parent.
    fn insertInto(self: *Tree, maybe: ?*Node, value: i32) !?*Node {
        const node = maybe orelse {
            const fresh = try self.allocator.create(Node);
            fresh.* = .{ .value = value };
            self.len += 1;
            return fresh;
        };

        if (value < node.value) {
            node.left = try self.insertInto(node.left, value);
        } else if (value > node.value) {
            node.right = try self.insertInto(node.right, value);
        } else {
            return node; // already present
        }

        refresh(node);

        // Four cases. The outer test says which side is too deep; the inner
        // test says whether the new node went to the outside of that side (one
        // rotation) or the inside (rotate the child first, then this node).
        const bias = balance(node);

        if (bias > 1 and value < node.left.?.value) {
            return self.rotateRight(node); // left-left
        }
        if (bias < -1 and value > node.right.?.value) {
            return self.rotateLeft(node); // right-right
        }
        if (bias > 1) { // left-right
            node.left = self.rotateLeft(node.left.?);
            return self.rotateRight(node);
        }
        if (bias < -1) { // right-left
            node.right = self.rotateRight(node.right.?);
            return self.rotateLeft(node);
        }
        return node;
    }

    fn contains(self: *const Tree, value: i32) bool {
        var current = self.root;
        while (current) |node| {
            if (value == node.value) return true;
            current = if (value < node.value) node.left else node.right;
        }
        return false;
    }

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

    /// Check the invariant everywhere rather than trusting the insert code.
    /// This is the assertion the whole chapter is about, so it is worth running
    /// rather than claiming.
    fn isBalanced(maybe: ?*Node) bool {
        const node = maybe orelse return true;
        if (@abs(balance(node)) > 1) return false;
        return isBalanced(node.left) and isBalanced(node.right);
    }

    fn writeShape(self: *const Tree, out: *std.Io.Writer) !void {
        try shape(out, self.root, 0);
    }

    fn shape(out: *std.Io.Writer, maybe: ?*Node, depth: usize) !void {
        const node = maybe orelse return;
        try shape(out, node.right, depth + 1);
        for (0..depth) |_| try out.writeAll("    ");
        try out.print("{d}\n", .{node.value});
        try shape(out, node.left, depth + 1);
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

    // The exact input that ruined the plain tree: 1 through 15, in order.
    var tree = Tree.init(allocator);
    defer tree.deinit();

    try out.writeAll("inserting 1..15 in order, height after each:\n ");
    for (1..16) |i| {
        try tree.insert(@intCast(i));
        try out.print("{d}", .{Tree.heightOf(tree.root)});
        if (i < 15) try out.writeAll(" ");
    }
    try out.writeByte('\n');

    try out.print("\nfinal height {d}, ideal {d}, rotations {d}\n", .{
        Tree.heightOf(tree.root),
        std.math.log2_int(usize, 15) + 1,
        tree.rotations,
    });
    try out.print("balanced everywhere: {}\n", .{Tree.isBalanced(tree.root)});

    try out.writeAll("\nin-order: ");
    try tree.writeInOrder(out);

    try out.writeAll("\nshape (rotate the page 90 degrees clockwise):\n");
    try tree.writeShape(out);

    // Every rotation preserves the in-order sequence, so a rebalanced tree
    // answers exactly the same questions as the tree it replaced.
    var missing: usize = 0;
    for (1..16) |i| {
        if (!tree.contains(@intCast(i))) missing += 1;
    }
    try out.print("\nvalues 1..15 still present: {d} of 15\n", .{15 - missing});

    // A worse input: strictly descending, which drives the mirror-image cases.
    var descending = Tree.init(allocator);
    defer descending.deinit();
    var i: i32 = 15;
    while (i >= 1) : (i -= 1) try descending.insert(i);
    try out.print("\ninserting 15..1: height {d}, rotations {d}, balanced {}\n", .{
        Tree.heightOf(descending.root),
        descending.rotations,
        Tree.isBalanced(descending.root),
    });

    // And the zig-zag input that needs the two-rotation cases.
    var zigzag = Tree.init(allocator);
    defer zigzag.deinit();
    for ([_]i32{ 1, 15, 2, 14, 3, 13, 4, 12, 5, 11, 6, 10, 7, 9, 8 }) |v| try zigzag.insert(v);
    try out.print("zig-zag input:   height {d}, rotations {d}, balanced {}\n", .{
        Tree.heightOf(zigzag.root),
        zigzag.rotations,
        Tree.isBalanced(zigzag.root),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.avl`)*

## The invariant

Each node stores its height, a leaf being 1. The balance factor is the left
height minus the right height, and the rule is that it stays within -1 to 1 at
every node in the tree.

```zig
fn balance(maybe: ?*Node) i32 {
    const node = maybe orelse return 0;
    return heightOf(node.left) - heightOf(node.right);
}
```

A factor of 2 means one side is a full level deeper than the other, which is
the moment to rotate. That bound is what keeps the height within about 1.44
log₂(n). It is looser than a red-black tree's, which is why AVL trees do more
rotations on insert and give slightly faster lookups in exchange.

The height is stored rather than computed. Computing it is the O(n) walk the
structure exists to avoid.

## A rotation is four pointer writes

```
      y            x
     / \          / \
    x   C   ->   A   y
   / \              / \
  A   B            B   C
```

Read both trees in order: `A x B y C`, before and after. The rotation
preserves the ordering, which is why it can be applied anywhere at any time
without checking whether it breaks the search property. Only `B` changes
parent.

```zig
fn rotateRight(self: *Tree, y: *Node) *Node {
    const x = y.left.?;
    y.left = x.right;
    x.right = y;
    refresh(y);   // y first: it is now the lower node
    refresh(x);
    self.rotations += 1;
    return x;
}
```

The `refresh` order matters. `y` is now below `x`, so its height has to be
correct before `x`'s can be computed from it.

## Four cases, and the reason there are four

Rebalancing happens on the way back *up* from the insertion point. Each node
on that path gets its height refreshed and its balance checked, and the
function returns the subtree's new root so a rotation relinks itself into its
parent:

```zig
node.left = try self.insertInto(node.left, value);
```

That assignment is the relink. It is why this insert is recursive when the
plain tree's was a loop.

Then:

```zig
if (bias > 1 and value < node.left.?.value) return self.rotateRight(node);
if (bias < -1 and value > node.right.?.value) return self.rotateLeft(node);
if (bias > 1) {
    node.left = self.rotateLeft(node.left.?);
    return self.rotateRight(node);
}
if (bias < -1) {
    node.right = self.rotateRight(node.right.?);
    return self.rotateLeft(node);
}
```

The outer test says which side got too deep. The inner test says whether the
new node went to the *outside* of that side or the *inside*. Outside is one
rotation. Inside is two. A single rotation on a zig-zag shape just produces
the mirror image of the same problem. Rotate the child first to straighten it
out, then rotate the node.

Four cases, and they are mirror images in pairs. That is the entire algorithm.

## It is cheap

```
inserting 1..15 in order, height after each:
 1 2 2 3 3 3 3 4 4 4 4 4 4 4 4
```

The height climbs to 4 and stops. Eleven rotations across fifteen inserts, and
each rotation is a handful of pointer writes on nodes that were just visited
and are still in cache. Rebalancing is not a periodic expensive pass; it is a
constant amount of work folded into the insert that caused it.

Three inputs, all landing balanced:

```
inserting 15..1: height 4, rotations 11, balanced true
zig-zag input:   height 5, rotations 16, balanced true
```

Descending input is the mirror of ascending and costs the same. The zig-zag
input, which alternates between extremes, is what drives the two-rotation
cases, and it costs more rotations for a slightly taller tree, still within
the bound.

## Checking rather than claiming

```zig
fn isBalanced(maybe: ?*Node) bool {
    const node = maybe orelse return true;
    if (@abs(balance(node)) > 1) return false;
    return isBalanced(node.left) and isBalanced(node.right);
}
```

The snippet walks the whole tree and checks the invariant at every node,
rather than trusting that the four cases were written correctly. It also
confirms all fifteen values are still findable afterwards, because a rotation
that is subtly wrong produces a tree that is beautifully balanced and has lost
a subtree.

For a structure whose entire purpose is maintaining an invariant, the
invariant check belongs in the code and not only in the prose.

## Deletion, which is not here

Insert is the easy half. Deleting an internal node means replacing it with its
in-order predecessor or successor, then rebalancing the whole path back to the
root. Unlike insertion, one deletion can require rotations at every level
rather than stopping after the first fix.

This is the usual point at which people switch to a red-black tree, whose
looser rule makes deletion cheaper. The other option is a treap, which avoids
the case analysis entirely by giving each node a random priority and keeping a
heap on it.
