# Keep It Balanced

> Store a height, check it after each insert, and repair the shape with a local rotation. Four cases, and each case has five lines or fewer.

On sorted input, the tree from the previous chapter becomes a linked list. An AVL tree prevents this problem with three additions:

- A height, stored in each node.
- A check after each insert.
- A rotation that repairs the shape when the check fails.

This is the result on the input that broke the plain tree:

```
final height 4, ideal 4, rotations 11
balanced everywhere: true
```

The program inserts fifteen values in ascending order. The tree has the minimum possible height, after eleven rotations.

```zig
const std = @import("std");

const Tree = struct {
    root: ?*Node = null,
    len: usize = 0,
    allocator: std.mem.Allocator,
    /// The program counts rotations. The output shows that the balance is
    /// cheap: a few rotations for a full tree, not one per node.
    rotations: usize = 0,

    const Node = struct {
        value: i32,
        left: ?*Node = null,
        right: ?*Node = null,
        /// A leaf has height 1. The node stores the height, and the code does
        /// not compute it again. To compute it again is an O(n) walk, and this
        /// structure exists to prevent that walk.
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

    /// Left height minus right height. The invariant is that this value stays
    /// in -1..1 for each node in the tree. Two means that one side is a full
    /// level deeper than the other side, and the node must rotate.
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
    /// B gets a different parent, and nothing else moves. The in-order
    /// sequence is A x B y C before and after. Thus a rotation keeps the
    /// search property with no extra work.
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

    /// Recursive, because the rebalance occurs on the path back *up*. On the
    /// path from the insertion point to the root, the code updates the height
    /// of each node and checks its balance. The function returns the root of
    /// the subtree, which can be a new root. That return links a rotation into
    /// its parent.
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

        // Four cases. The outer test tells which side is too deep. The inner
        // test tells where the new node went on that side. On the outside,
        // do one rotation. On the inside, rotate the child, then this node.
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

    /// Check the invariant at each node, and do not trust the insert code.
    /// The chapter is about this invariant. Thus the program checks it, and
    /// does not only claim it.
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

    // The input that made the plain tree into one long chain: 1 to 15, in order.
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

    // Each rotation keeps the in-order sequence. Thus a rebalanced tree gives
    // exactly the same answers as the tree that it replaced.
    var missing: usize = 0;
    for (1..16) |i| {
        if (!tree.contains(@intCast(i))) missing += 1;
    }
    try out.print("\nvalues 1..15 still present: {d} of 15\n", .{15 - missing});

    // A different input: strictly descending. It causes the mirror-image cases.
    var descending = Tree.init(allocator);
    defer descending.deinit();
    var i: i32 = 15;
    while (i >= 1) : (i -= 1) try descending.insert(i);
    try out.print("\ninserting 15..1: height {d}, rotations {d}, balanced {}\n", .{
        Tree.heightOf(descending.root),
        descending.rotations,
        Tree.isBalanced(descending.root),
    });

    // The zig-zag input. It needs the cases with two rotations.
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

Each node stores its height, and the height of a leaf is 1. The balance factor is the left height minus the right height. The rule is that the balance factor stays in the range -1 to 1 at each node in the tree.

```zig
fn balance(maybe: ?*Node) i32 {
    const node = maybe orelse return 0;
    return heightOf(node.left) - heightOf(node.right);
}
```

A factor of 2 means that one side is a full level deeper than the other side. At that time, the tree must rotate. The bound keeps the height below approximately 1.44 log₂(n). A red-black tree allows a looser bound. Thus an AVL tree does more rotations on insert, and in exchange it gives slightly faster lookups.

The height is a stored value, not a computed value. To compute the height, the code must do an O(n) walk, and the structure exists to prevent that walk.

## A rotation is four pointer writes

```
      y            x
     / \          / \
    x   C   ->   A   y
   / \              / \
  A   B            B   C
```

Read the two trees in order: `A x B y C`, before and after. The rotation keeps the order. Thus you can apply a rotation at any location and at any time, and you do not have to check the search property. Only `B` gets a different parent.

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

The order of the `refresh` calls is important. `y` is now below `x`. Thus the height of `y` must be correct before the code computes the height of `x` from it.

## Four cases, and the reason for four

The tree rebalances on the path back *up* from the insertion point. On that path, the code refreshes the height of each node and checks its balance. The function returns the new root of the subtree. Thus a rotation links itself into its parent:

```zig
node.left = try self.insertInto(node.left, value);
```

That assignment is the relink. Because of the relink, this insert is recursive, but the insert of the plain tree was a loop.

Then the code does these tests:

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

The outer test tells which side became too deep. The inner test tells if the new node went to the *outside* of that side or to the *inside*:

- On the outside, one rotation is sufficient.
- On the inside, two rotations are necessary.

A single rotation on a zig-zag shape only makes the mirror image of the same problem. First, rotate the child to make the shape straight. Then rotate the node.

The four cases are two pairs of mirror images.

## The balance is cheap

```
inserting 1..15 in order, height after each:
 1 2 2 3 3 3 3 4 4 4 4 4 4 4 4
```

The height increases to 4 and stops. Fifteen inserts cause eleven rotations. Each rotation is a small number of pointer writes. The insert visited these nodes a short time before, and the nodes are still in cache. The rebalance is not a periodic expensive pass. It is a constant quantity of work inside the insert that caused it.

Three inputs, and each result has a good balance:

```
inserting 15..1: height 4, rotations 11, balanced true
zig-zag input:   height 5, rotations 16, balanced true
```

Descending input is the mirror of ascending input and has the same cost. The zig-zag input alternates between the extremes, and it causes the cases with two rotations. It costs more rotations and makes a slightly taller tree, but the height is still in the bound.

## Check the invariant, do not only claim it

```zig
fn isBalanced(maybe: ?*Node) bool {
    const node = maybe orelse return true;
    if (@abs(balance(node)) > 1) return false;
    return isBalanced(node.left) and isBalanced(node.right);
}
```

The snippet walks the full tree and checks the invariant at each node. It does not trust that the four cases are correct. After the inserts, the snippet also checks that it can still find all fifteen values. A rotation with a small error can make a tree that is well balanced but has lost a subtree.

When a structure exists to keep an invariant, the check for the invariant must be in the code, and not only in the prose.

## Deletion, and why this chapter does not include it

Insert is the easy half. To delete an internal node, replace the node with its in-order predecessor or successor. Then rebalance the full path back to the root. Insertion stops after the first repair, but one deletion can need rotations at each level.

At that point, most people change to a red-black tree, because its looser rule makes deletion cheaper. The other option is a treap. A treap gives each node a random priority and keeps a heap on these priorities. Thus a treap does not need the analysis of cases at all.
