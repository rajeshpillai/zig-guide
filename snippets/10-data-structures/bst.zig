//! title: A Binary Search Tree
//! Two pointers instead of one buys ordered iteration and O(log n) lookup, on
//! one condition that the structure itself does nothing to enforce. This
//! chapter is mostly about what happens when that condition fails.

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

    /// Post-order, and it has to be. Freeing a node before its children leaves
    /// no way to reach them, which is a leak the compiler cannot catch and the
    /// leak-checking allocator in `main` will.
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

    /// Insert, iteratively.
    ///
    /// The recursive version reads better and is what most textbooks show. This
    /// one is written as a loop over a pointer-to-pointer, which is the trick
    /// worth knowing: `link` points at the slot the new node goes in, so the
    /// null case and the ordinary case are the same code and there is no
    /// special handling for an empty tree.
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

    /// Left, self, right. The defining property: this visits the values in
    /// sorted order, which is the reason to pay for a tree rather than a hash
    /// table when order matters.
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

    /// Longest path from the root to a leaf. This is the number that decides
    /// whether lookup is fast, and nothing in `insert` controls it.
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

    // Insertion order decides the shape, and the shape decides everything else.
    // A tree built from sorted input never branches: every value is larger than
    // the last, so it goes right, every time.
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

    // Both still iterate in order. The invariant holds; only the cost changed.
    try out.writeAll("\ndegenerate tree, in-order: ");
    try degenerate.writeInOrder(out);

    // Comparisons to find the largest value, counted rather than asserted.
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
