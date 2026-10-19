//! title: A Linked List by Hand
//! The smallest structure that needs an allocator, a nullable pointer and a
//! deinit with the correct order. A first container teaches these three parts
//! of Zig better than a separate explanation of each part.

const std = @import("std");

const Node = struct {
    value: i32,
    /// `?*Node`, not `*?Node`. This is an optional pointer to a node: it is
    /// null or the address of a node. `*?Node` is a pointer to a slot that can
    /// hold a node. That is a different thing, and the slot must exist in a
    /// different location.
    next: ?*Node = null,
};

const List = struct {
    head: ?*Node = null,
    /// This field makes `append` O(1). Without it, an append to a list of n
    /// items walks all n items, and a list of n items costs O(n^2) to build.
    tail: ?*Node = null,
    len: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    /// The list owns each node that it allocates. Thus the list frees the
    /// nodes. The walk has one rule about order, and the rule is easy to
    /// break: read `next` *before* you destroy the node that contains it.
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

    /// Remove the first node that holds `value`.
    ///
    /// The difficult part of a singly linked list: to unlink a node, you need
    /// the node *before* it. You cannot get to that node from the node itself.
    /// The usual solution is to keep `previous` during the walk. The cost is a
    /// special case for the head.
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

    // An allocator that checks for leaks. A container that gives out memory is
    // exactly the place where a leak starts. `deinit` returns the number of
    // allocations that the program did not free.
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

    // An optional pointer takes no extra space. Zig knows that a valid pointer
    // can never be zero. Thus Zig uses zero as the null tag, and adds no flag
    // beside the pointer. `?*T` is the idiomatic way to say "maybe a node",
    // and a hand-written sentinel value saves nothing.
    //
    // The program prints sizes in pointer widths, not bytes. Thus the answers
    // are the same as wasm32 in your browser and natively on a 64-bit
    // computer. The relations between the sizes are important here. The byte
    // counts depend on the target.
    try out.print("\n@sizeOf(?*Node) == @sizeOf(*Node) -> {}\n", .{@sizeOf(?*Node) == @sizeOf(*Node)});
    try out.print("@sizeOf(?i32)    > @sizeOf(i32)    -> {} (an integer has no spare value to mean null)\n", .{@sizeOf(?i32) > @sizeOf(i32)});
    try out.print("@sizeOf(Node) in pointers = {d}\n", .{@sizeOf(Node) / @sizeOf(usize)});

    try out.flush();
}
