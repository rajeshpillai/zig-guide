# Interfaces

> No interface keyword. Four shapes instead, and what each shape costs.

Zig has no `interface` keyword. It has no `trait`, no `impl` and no `implements`. But the standard library has many interfaces. `std.mem.Allocator` is one, `std.Io` is one, and `std.Io.Writer` is one.

The standard library makes them from parts that you already know: `anytype`, tagged unions, function pointers and `@fieldParentPtr`. There are four common ways to put those parts together. Each way loses a different thing.

This chapter makes the same small interface in the four ways. Thus you can see the cost of each way.

```zig
const std = @import("std");

// Two sinks. Neither sink knows about the other sink.

const Counter = struct {
    lines: usize = 0,
    bytes: usize = 0,

    pub fn write(self: *Counter, line: []const u8) void {
        self.lines += 1;
        self.bytes += line.len;
    }

    pub fn sink(self: *Counter) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .write = writeOpaque };

    fn writeOpaque(ptr: *anyopaque, line: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.write(line);
    }
};

const Last = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    pub fn write(self: *Last, line: []const u8) void {
        self.len = @min(line.len, self.buf.len);
        @memcpy(self.buf[0..self.len], line[0..self.len]);
    }

    pub fn text(self: *const Last) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn sink(self: *Last) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .write = writeOpaque };

    fn writeOpaque(ptr: *anyopaque, line: []const u8) void {
        const self: *Last = @ptrCast(@alignCast(ptr));
        self.write(line);
    }
};

// 1. anytype: the compiler checks the shape at each call site.

fn sendAll(target: anytype, lines: []const []const u8) void {
    comptime requireSink(@TypeOf(target));
    for (lines) |line| target.write(line);
}

fn requireSink(comptime T: type) void {
    if (!std.meta.hasMethod(T, "write")) {
        @compileError(@typeName(T) ++ " is not a sink: it has no write method");
    }
}

// 2. A tagged union: a closed list of implementations.

const AnySink = union(enum) {
    counter: Counter,
    last: Last,

    pub fn write(self: *AnySink, line: []const u8) void {
        switch (self.*) {
            inline else => |*s| s.write(line),
        }
    }
};

// 3. A pointer and a vtable: the shape of std.mem.Allocator and std.Io.

const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, line: []const u8) void,
    };

    pub fn write(self: Sink, line: []const u8) void {
        self.vtable.write(self.ptr, line);
    }
};

// 4. An embedded interface: the shape of std.Io.Writer.

const Out = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (out: *Out, line: []const u8) void,
    };

    pub fn write(self: *Out, line: []const u8) void {
        self.vtable.write(self, line);
    }
};

const Shouter = struct {
    shouted: usize = 0,
    interface: Out = .{ .vtable = &vtable },

    const vtable: Out.VTable = .{ .write = write };

    fn write(out: *Out, line: []const u8) void {
        const self: *Shouter = @fieldParentPtr("interface", out);
        for (line) |c| {
            if (c == '!') self.shouted += 1;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const lines = [_][]const u8{ "boot", "disk ok", "network down!" };

    try out.print("-- anytype\n", .{});
    var counter: Counter = .{};
    var last: Last = .{};
    sendAll(&counter, &lines);
    sendAll(&last, &lines);
    try out.print("counter: {d} lines, {d} bytes\n", .{ counter.lines, counter.bytes });
    try out.print("last: \"{s}\"\n", .{last.text()});

    try out.print("-- tagged union\n", .{});
    var mixed = [_]AnySink{ .{ .counter = .{} }, .{ .last = .{} } };
    for (&mixed) |*s| {
        for (lines) |line| s.write(line);
    }
    try out.print("counter: {d} lines\n", .{mixed[0].counter.lines});
    try out.print("last: \"{s}\"\n", .{mixed[1].last.text()});

    try out.print("-- vtable\n", .{});
    var counter2: Counter = .{};
    var last2: Last = .{};
    const sinks = [_]Sink{ counter2.sink(), last2.sink() };
    for (sinks) |s| {
        for (lines) |line| s.write(line);
    }
    try out.print("counter: {d} lines\n", .{counter2.lines});
    try out.print("last: \"{s}\"\n", .{last2.text()});
    try out.print("a Sink is two pointers: {}\n", .{@sizeOf(Sink) == 2 * @sizeOf(usize)});

    try out.print("-- embedded\n", .{});
    var shouter: Shouter = .{};
    const iface = &shouter.interface;
    for (lines) |line| iface.write(line);
    try out.print("shouted: {d}\n", .{shouter.shouted});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.interfaces`)*

## The task

A sink takes lines of text. The program has two sinks:

- `Counter` counts lines and bytes.
- `Last` keeps a copy of the most recent line.

The two types have a method with the same signature, `write(self, line: []const u8) void`. Neither type knows about the other type.

The question is how to write code that works with the two types.

## 1. `anytype`: a check at each call

```zig
fn sendAll(target: anytype, lines: []const []const u8) void {
    comptime requireSink(@TypeOf(target));
    for (lines) |line| target.write(line);
}
```

*Quoted from the source: `sendAll` from `snippets/02-language/interfaces.zig`.*

`sendAll` never names a type. It calls `target.write` and expects that the method exists. The compiler checks this at each call.

`sendAll(&counter, ...)` compiles one copy of `sendAll` for `*Counter`. `sendAll(&last, ...)` compiles a second copy for `*Last`.

```
-- anytype
counter: 3 lines, 24 bytes
last: "network down!"
```

Each call to `write` is a direct call. The program does no lookup at runtime. Thus the optimizer can inline `write` into the loop.

This is how generic code works in Zig. [Comptime](https://www.ziglang.in/learn/language-basics/comptime/) shows the `comptime T: type` form. `anytype` is the same idea, but the type comes from the argument. You do not pass the type yourself.

The standard library uses `anytype` in many places. `std.mem.sort` takes its `context` as `anytype`, and most functions that accept a callback do the same.

### Give the caller a better error

If you remove the first line of `sendAll` and pass an integer, the error points at `target.write` inside `sendAll`. The person who made the mistake must read your function to find what it needs.

`requireSink` runs first and gives the problem in words:

```zig
fn requireSink(comptime T: type) void {
    if (!std.meta.hasMethod(T, "write")) {
        @compileError(@typeName(T) ++ " is not a sink: it has no write method");
    }
}
```

*Quoted from the source: `requireSink` from `snippets/02-language/interfaces.zig`.*

`std.meta.hasMethod` looks through one pointer. Thus `*Counter` passes the check and `*u32` fails it. Now the build stops with `*u32 is not a sink: it has no write method`.

`@compileError` stops the build. It does not return an error value, and no part of it gets into the program at runtime.

### The limits of `anytype`

You cannot put a `Counter` and a `Last` in the same array. No type means "any sink". Thus you have no type for the declaration of the array.

Also, each new type compiles one more copy of the function. For a three-line loop, the cost is too small to measure. For a large function that callers use with many types, the binary becomes larger.

## 2. A tagged union: a closed list

```zig
const AnySink = union(enum) {
    counter: Counter,
    last: Last,

    pub fn write(self: *AnySink, line: []const u8) void {
        switch (self.*) {
            inline else => |*s| s.write(line),
        }
    }
};
```

*Quoted from the source: `AnySink` from `snippets/02-language/interfaces.zig`.*

`AnySink` is one type. Thus an array can hold the two kinds of sink.

`inline else` makes the compiler write one prong for each field. Inside each prong, `s` has the real type. Thus `s.write` is a direct call again.

```
-- tagged union
counter: 3 lines
last: "network down!"
```

The list of implementations is closed. A new kind of sink needs a new field in `AnySink`, and only the code that owns `AnySink` can add one.

Often this is exactly correct. The tokens of a parser, the instructions of a small VM and the values in a JSON document are all fixed lists. For this reason, `std.json.Value` is a `union(enum)`.

An `AnySink` is as large as its largest member, plus the tag. `Last` contains a 32-byte buffer. Thus each `AnySink` uses the space for that buffer, also an `AnySink` that holds a `Counter`.

[Unions](https://www.ziglang.in/learn/language-basics/unions/) explains the type itself.

## 3. A pointer and a vtable: an open list

```zig
const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, line: []const u8) void,
    };

    pub fn write(self: Sink, line: []const u8) void {
        self.vtable.write(self.ptr, line);
    }
};
```

*Quoted from the source: `Sink` from `snippets/02-language/interfaces.zig`.*

A `Sink` holds two things:

- `ptr` points at the real object.
- `vtable` points at a table of functions that know how to use the object.

`*anyopaque` is a pointer to a value of unknown type. The `Sink` does not know what it points at, and it does not need to know.

Each implementation supplies the table, and a function that makes a `Sink` from the implementation:

```zig
const Counter = struct {
    lines: usize = 0,
    bytes: usize = 0,

    pub fn write(self: *Counter, line: []const u8) void {
        self.lines += 1;
        self.bytes += line.len;
    }

    pub fn sink(self: *Counter) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .write = writeOpaque };

    fn writeOpaque(ptr: *anyopaque, line: []const u8) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.write(line);
    }
};
```

*Quoted from the source: `Counter` from `snippets/02-language/interfaces.zig`.*

`writeOpaque` gets the `*anyopaque` and casts it back to `*Counter`. Then it calls the real `write`.

The cast is correct only because `sink()` stored a `*Counter` in `ptr`. The compiler cannot check this for you. If the table of one type is in a pair with the pointer of a different type, the cast still compiles.

`vtable` is a `const` declaration in the struct, not a field. It exists one time in the program. Each `Sink` that a `Counter` makes points at the same table.

Now two unrelated types fit in one array:

```
-- vtable
counter: 3 lines
last: "network down!"
a Sink is two pointers: true
```

This is the shape of `std.mem.Allocator`. In its source, the first two fields are `ptr: *anyopaque` and `vtable: *const VTable`. `std.Io` has the same structure, but its pointer has the name `userdata`.

Thus you can pass an `ArenaAllocator` or a `SafeAllocator` where the code wants an `Allocator`. A library that you do not know can also add its own allocator, and it does not change `std`. The list is open.

Each call goes through a function pointer. Usually the optimizer cannot inline a call through a function pointer.

Also, the `Sink` does not own the object. If the scope of `counter2` ends while a `Sink` still points at `counter2`, `ptr` becomes a dangling pointer.

The table holds the function pointers, and the `Sink` does not. Thus a `Sink` stays at two pointers when the interface gets more methods, because one table serves all `Counter` values.

## 4. An embedded interface: `@fieldParentPtr`

`std.Io.Writer` moves the interface into the object. The interface is not a separate value that points at the object. It is a field inside the object.

```zig
const Out = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (out: *Out, line: []const u8) void,
    };

    pub fn write(self: *Out, line: []const u8) void {
        self.vtable.write(self, line);
    }
};
```

*Quoted from the source: `Out` from `snippets/02-language/interfaces.zig`.*

```zig
const Shouter = struct {
    shouted: usize = 0,
    interface: Out = .{ .vtable = &vtable },

    const vtable: Out.VTable = .{ .write = write };

    fn write(out: *Out, line: []const u8) void {
        const self: *Shouter = @fieldParentPtr("interface", out);
        for (line) |c| {
            if (c == '!') self.shouted += 1;
        }
    }
};
```

*Quoted from the source: `Shouter` from `snippets/02-language/interfaces.zig`.*

The vtable function receives a `*Out`. That pointer points at the `interface` field inside a `Shouter`.

`@fieldParentPtr("interface", out)` subtracts the offset of the field from that address. It gives back the `*Shouter` that contains the field. The code has no `*anyopaque` and no stored pointer to the parent.

```
-- embedded
shouted: 1
```

The advantage is that the interface can hold its own state. `std.Io.Writer` keeps its buffer in the interface. `print` fills that buffer with usual code. It calls through the vtable only when the buffer is full or when you call `flush`. Thus most writes never make an indirect call.

You already used this shape. Each program on this site writes `const out = &file_writer.interface;` before it prints anything.

The `&` is important. `@fieldParentPtr` works only while the interface is still inside its parent.

If you copy the interface with `var copy = file_writer.interface;`, the vtable function subtracts the offset from the address of the copy. The result is memory that is not a `File.Writer`. This code compiles, and a safe build does not find the problem.

In a test on `Shouter`, a `ReleaseSafe` build ran without a panic and printed `shouted: 0`. The behaviour is undefined, thus a different build can do something worse.

Take the address of an embedded interface. Do not copy it.

[Linked lists in std](https://www.ziglang.in/learn/data-structures/std-lists/) use the same builtin for a different task: to find your struct from the list node inside it.

## Select a shape

| Shape | Who can add an implementation | How `write` is called | One array of mixed types | In `std` |
| --- | --- | --- | --- | --- |
| `anytype` | anyone | directly, can inline | no | `std.mem.sort`'s `context` |
| tagged union | only the union's owner | switch, then directly | yes | `std.json.Value` |
| pointer and vtable | anyone | through a pointer | yes | `std.mem.Allocator`, `std.Io` |
| embedded interface | anyone | through a pointer, but often no call | yes, as pointers | `std.Io.Writer`, `std.Io.Reader` |

Use these rules:

- Start with `anytype`. It needs the least code, and it gives the fastest call.
- Change to a tagged union when you need a mixed list and you own each type in the list.
- Change to a vtable when code that you do not control must add an implementation.
- Use the embedded form only when the interface has its own state, as a writer has its buffer. Only then is the form worth its extra rules.

## If you know other languages

In Rust, generics with trait bounds do the job of `anytype`, and an `enum` is a tagged union. A Rust `&dyn Trait` is a data pointer and a vtable pointer. This is the same pair that `Sink` holds.

A Go interface value is also two words. One word points at the method table of the type, and the other word points at the data.

The difference in Zig is that you write the table yourself.
