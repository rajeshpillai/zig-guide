//! title: Making It Generic
//! Zig has no separate generics syntax. A generic container is a function that
//! takes a type at compile time and returns a type, which is why the same
//! mechanism that writes `List(T)` also writes `ArrayList` and `HashMap`.

const std = @import("std");

/// A function from a type to a type. Called at compile time, so by the time the
/// program runs `List(i32)` is an ordinary struct with no type parameter left
/// in it and no indirection to pay for.
fn List(comptime T: type) type {
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        len: usize = 0,
        allocator: std.mem.Allocator,

        /// `@This()` names the struct being defined. Inside a type function the
        /// struct is anonymous, so there is no other way to refer to it, and
        /// `Self` is the conventional name for the result.
        const Self = @This();

        /// The node type is nested, so `List(i32).Node` and `List(u8).Node` are
        /// distinct types and neither can be passed to the other's list.
        pub const Node = struct {
            value: T,
            next: ?*Node = null,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.* = init(self.allocator);
        }

        pub fn append(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .value = value };

            if (self.tail) |tail| tail.next = node else self.head = node;
            self.tail = node;
            self.len += 1;
        }

        /// Equality has to come from somewhere. `std.meta.eql` compares field
        /// by field and works for integers, structs of integers and enums; it
        /// compares slices by pointer, not by content, which is why the string
        /// list below uses its own comparison.
        pub fn contains(self: *const Self, value: T) bool {
            var current = self.head;
            while (current) |node| : (current = node.next) {
                if (std.meta.eql(node.value, value)) return true;
            }
            return false;
        }

        pub fn write(self: *const Self, out: *std.Io.Writer) !void {
            var current = self.head;
            try out.writeAll("[");
            while (current) |node| : (current = node.next) {
                try out.print("{any}", .{node.value});
                if (node.next != null) try out.writeAll(", ");
            }
            try out.writeAll("]\n");
        }
    };
}

const Point = struct { x: i32, y: i32 };

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();

    var numbers = List(i32).init(allocator);
    defer numbers.deinit();
    for ([_]i32{ 3, 1, 4, 1, 5 }) |v| try numbers.append(v);
    try out.writeAll("List(i32):   ");
    try numbers.write(out);

    var points = List(Point).init(allocator);
    defer points.deinit();
    try points.append(.{ .x = 1, .y = 2 });
    try points.append(.{ .x = 3, .y = 4 });
    try out.writeAll("List(Point): ");
    try points.write(out);

    try out.print("\ncontains(4)          -> {}\n", .{numbers.contains(4)});
    try out.print("contains(9)          -> {}\n", .{numbers.contains(9)});
    try out.print("contains(Point 3,4)  -> {}\n", .{points.contains(.{ .x = 3, .y = 4 })});

    // The type function is memoized: calling it twice with the same argument
    // returns the same type, not two structurally identical ones. That is what
    // makes `List(i32)` usable as a type annotation in a signature.
    try out.print("\n@typeName(List(i32))  = {s}\n", .{@typeName(List(i32))});
    try out.print("List(i32) == List(i32) -> {}\n", .{List(i32) == List(i32)});
    try out.print("List(i32) == List(u8)  -> {}\n", .{List(i32) == List(u8)});

    // The nested node type is instantiated along with its list, so each
    // instantiation gets its own node type laid out for its own T. There is no
    // boxing and no shared code path: this is monomorphization, the same thing
    // a C++ template or a Rust generic does, reached without a second syntax.
    try out.print("\n@typeName(List(u8).Node)    = {s}\n", .{@typeName(List(u8).Node)});
    try out.print("@typeName(List(Point).Node) = {s}\n", .{@typeName(List(Point).Node)});
    try out.print("List(u8).Node == List(i32).Node -> {}\n", .{List(u8).Node == List(i32).Node});

    // `std.ArrayList` is the same idea with contiguous storage instead of
    // nodes. It is a type function too, and on master it does not hold the
    // allocator: every method that can allocate takes one.
    var array: std.ArrayList(i32) = .empty;
    defer array.deinit(allocator);
    for ([_]i32{ 3, 1, 4 }) |v| try array.append(allocator, v);
    try out.print("\nstd.ArrayList(i32): {any}\n", .{array.items});

    try out.flush();
}
