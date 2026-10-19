//! title: The Lists in std Are Intrusive
//! `std.SinglyLinkedList` is not generic and does not hold your data. Put its
//! node in your own struct, and get back to the struct with `@fieldParentPtr`.
//! Tutorials from before this change show a different design.

const std = @import("std");

/// The list node is *inside* the value that is in the list. This is the
/// meaning of intrusive: your value contains the bookkeeping of the container,
/// and the container does not wrap your value.
const Task = struct {
    name: []const u8,
    priority: u8,
    node: std.SinglyLinkedList.Node = .{},

    /// From a pointer to the embedded node, get the struct that contains it.
    ///
    /// `@fieldParentPtr` subtracts the offset of the field from the pointer.
    /// The compiler checks it at compile time. The field name must exist on
    /// the result type, and the field must have the type of the pointee. Thus
    /// this line looks dangerous, but it cannot silently point at the wrong
    /// thing.
    fn fromNode(node: *std.SinglyLinkedList.Node) *Task {
        return @fieldParentPtr("node", node);
    }
};

/// A doubly linked version. It shows the same shape with a second list type.
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

    // The tasks are in the location that you select. Here, that location is
    // the stack. The list allocates nothing: the program gives it no
    // allocator, and `prepend` cannot fail. The intrusive design has this
    // purpose.
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

    // `remove` takes the node, and you can get to the node from the task.
    // Thus "remove this task" needs no search. On the hand-written list two
    // chapters ago, the same operation was a walk from the head.
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

    // A node is two words or less and carries no payload. Thus the cost of a
    // list membership is fixed, and you can see it in the struct that holds
    // the node. The sizes are in pointer widths, so the numbers are the same
    // on wasm32 and on a 64-bit native build.
    try out.print("\nsizes in pointer widths\n", .{});
    try out.print("  SinglyLinkedList.Node = {d}\n", .{@sizeOf(std.SinglyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  DoublyLinkedList.Node = {d}\n", .{@sizeOf(std.DoublyLinkedList.Node) / @sizeOf(usize)});
    try out.print("  Task                  = {d} (a slice, a byte, and the node, padded)\n", .{@sizeOf(Task) / @sizeOf(usize)});

    // A task that holds more than one node can be on more than one list at
    // the same time. A list that wraps values cannot do this unless it
    // allocates a second node for each membership.
    try out.print("\nlists are types, not type functions: {s}, {s}\n", .{
        @typeName(std.SinglyLinkedList), @typeName(std.DoublyLinkedList),
    });

    try out.flush();
}
