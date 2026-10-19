//! title: Making It Generic
//! Zig has no separate generics syntax. A generic container is a function that
//! takes a type at compile time and returns a type. The same mechanism makes
//! `List(T)`, `ArrayList` and `HashMap`.

const std = @import("std");

/// A function from a type to a type. The call occurs at compile time. Thus,
/// when the program runs, `List(i32)` is an ordinary struct. It has no type
/// parameter and no extra indirection at run time.
fn List(comptime T: type) type {
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        len: usize = 0,
        allocator: std.mem.Allocator,

        /// `@This()` gives the struct that this code defines. Inside a type
        /// function, the struct is anonymous. No other way to refer to the
        /// struct exists. `Self` is the conventional name for the result.
        const Self = @This();

        /// The node type is nested. Thus `List(i32).Node` and `List(u8).Node`
        /// are different types, and you cannot give one to the other list.
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

        /// Equality must have a definition. `std.meta.eql` compares field by
        /// field. It works for integers, structs of integers and enums. It
        /// compares slices by pointer, not by content. Thus a list of strings
        /// needs its own comparison.
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

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(safe.deinit() == 0);
    const allocator = safe.allocator();

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

    // The type function is memoized. Two calls with the same argument return
    // the same type, not two types with the same structure. Memoization lets
    // you use `List(i32)` as a type annotation in a signature.
    try out.print("\n@typeName(List(i32))  = {s}\n", .{@typeName(List(i32))});
    try out.print("List(i32) == List(i32) -> {}\n", .{List(i32) == List(i32)});
    try out.print("List(i32) == List(u8)  -> {}\n", .{List(i32) == List(u8)});

    // The compiler instantiates the nested node type together with its list.
    // Thus each instantiation gets its own node type, with a layout for its
    // own T. The values are not boxed, and the types share no code path. This is
    // monomorphization. A C++ template or a Rust generic does the same thing.
    // Zig uses ordinary function syntax for it, not a separate syntax.
    try out.print("\n@typeName(List(u8).Node)    = {s}\n", .{@typeName(List(u8).Node)});
    try out.print("@typeName(List(Point).Node) = {s}\n", .{@typeName(List(Point).Node)});
    try out.print("List(u8).Node == List(i32).Node -> {}\n", .{List(u8).Node == List(i32).Node});

    // `std.ArrayList` uses the same idea, with contiguous storage instead of
    // nodes. It is also a type function. On master, it does not hold the
    // allocator: each method that can allocate takes an allocator.
    var array: std.ArrayList(i32) = .empty;
    defer array.deinit(allocator);
    for ([_]i32{ 3, 1, 4 }) |v| try array.append(allocator, v);
    try out.print("\nstd.ArrayList(i32): {any}\n", .{array.items});

    try out.flush();
}
