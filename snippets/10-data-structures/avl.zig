//! title: Keeping It Balanced
//! The previous chapter's tree degenerates into a list on sorted input. Store a
//! height in each node, check it after every insert, and repair it with a local
//! rotation: four cases, none of them longer than five lines.

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

    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();

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
