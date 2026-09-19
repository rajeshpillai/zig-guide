# Making It Generic

> Zig has no generics syntax. A generic container is a function that takes a type and returns a type, evaluated at compile time.

The list in the previous chapter holds `i32` and nothing else. Making it hold
anything does not need a new language feature, because Zig already has
functions and types are already values at compile time.

```zig
fn List(comptime T: type) type {
    return struct {
        head: ?*Node = null,
        // ...
        const Self = @This();
        pub const Node = struct {
            value: T,
            next: ?*Node = null,
        };
    };
}
```

`List` is an ordinary function. Its argument happens to be a type, its return
value happens to be a type, and `comptime` on the parameter says it must be
known when the function is called. There is no separate generics system to
learn; this is the same mechanism [comptime](https://www.ziglang.in/learn/language-basics/comptime/)
describes, applied to a struct definition.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`10-data-structures.generic-list`)*

## `@This()` and why `Self` is a convention

Inside a type function the struct being defined is anonymous, so there is no
name to refer to it by. `@This()` returns it, and `const Self = @This()` gives
that name locally. It appears in almost every Zig container because it has to.

## The call is memoized

```
List(i32) == List(i32) -> true
List(i32) == List(u8)  -> false
```

Calling a type function twice with the same argument returns *the same type*,
not two structurally identical ones. Without that, `fn takes(list: List(i32))`
could not be called with a `List(i32)` built elsewhere, because they would be
different types. It is what makes type functions usable in signatures at all.

## Each instantiation is a real struct

```
@typeName(List(u8).Node)    = generic-list.List(u8).Node
@typeName(List(Point).Node) = generic-list.List(generic-list.Point).Node
List(u8).Node == List(i32).Node -> false
```

The nested `Node` is instantiated along with its list, so every `List(T)` gets
its own node type laid out for its own `T`. There is no boxing, no type
erasure and no shared code path with a size parameter threaded through it.
This is monomorphization, the same thing a C++ template or a Rust generic
does, reached without a second syntax and without a separate compilation
phase.

The nesting also means `List(i32).Node` and `List(u8).Node` are unrelated
types, so a node from one list cannot be handed to the other. That falls out
of the structure rather than being a rule anyone had to write down.

## Equality has to come from somewhere

`contains` needs to compare two `T` values, and `T` is not known when the code
is written. `std.meta.eql` compares field by field and handles integers,
enums, and structs of those, which covers the two examples in the snippet.

It has a sharp edge worth knowing: it compares slices by pointer and length,
not by content. `std.meta.eql` on two `[]const u8` holding the same characters
at different addresses returns false. A container that needs to compare
strings has to be told how. That is why `StringHashMap` exists as a separate
thing from `AutoHashMap`, rather than being a special case inside it.

The general answer is to take the comparison as a parameter, the same way
[sorting](https://www.ziglang.in/learn/standard-library/sorting/) takes a `lessThan`. A container
that hardcodes `std.meta.eql` works until the first type it is wrong for.

## This is what std is

```zig
var array: std.ArrayList(i32) = .empty;
defer array.deinit(allocator);
try array.append(allocator, 3);
```

[ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/) is the same idea with
contiguous storage instead of nodes, and `std.ArrayList(i32)` is a call to a
type function exactly like `List(i32)`. Reading `std` gets easier once that
stops looking like special syntax.

One difference worth copying: on master `ArrayList` does not store the
allocator. Every method that can allocate takes one as an argument. The list
in this chapter stores it, which is more convenient and costs a pointer in
every instance, and means two lists can never share one arena's worth of
bookkeeping. The unmanaged form is the direction std has moved in.
