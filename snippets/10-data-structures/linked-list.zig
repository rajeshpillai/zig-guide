//! title: A Linked List by Hand
//! The smallest structure that needs an allocator, a nullable pointer and a
//! deinit that gets the order right. All three are the parts of Zig that a
//! first container teaches better than any explanation of them separately.

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
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();

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
