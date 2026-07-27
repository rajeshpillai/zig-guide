//! title: The Lists in std Are Intrusive
//! `std.SinglyLinkedList` is not generic and does not hold your data. You embed
//! its node in your own struct and walk back out with `@fieldParentPtr`. Every
//! tutorial written before this change shows something else.

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
