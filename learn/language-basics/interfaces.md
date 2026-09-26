# Interfaces

> No interface keyword. Four shapes instead, and the trade each one makes.

Zig has no `interface` keyword.

There is no `trait`, no `impl` and no `implements`.

The standard library is still full of interfaces.

`std.mem.Allocator` is one, and so is `std.Io`, and so is `std.Io.Writer`.

They are built from parts you have already met: `anytype`, tagged unions, function pointers and `@fieldParentPtr`.

There are four common ways to put those parts together.

Each one gives up something different.

We'll build the same small interface all four ways, so you can see what each one costs.

```zig
const std = @import("std");

// Two sinks. Neither knows the other exists.

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

## The job

A sink takes lines of text.

We have two of them.

`Counter` counts lines and bytes.

`Last` keeps a copy of the most recent line.

Both have a method with the same signature, `write(self, line: []const u8) void`.

Neither type knows the other exists.

The question is how to write code that works with either one.

## 1. `anytype`: checked at each call

<SnippetSource name="02-language.interfaces" decl="sendAll" />

`sendAll` never names a type.

It calls `target.write` and expects it to be there.

The compiler checks that at every call.

`sendAll(&counter, ...)` compiles one copy of `sendAll` for `*Counter`, and `sendAll(&last, ...)` compiles a second copy for `*Last`.

```
-- anytype
counter: 3 lines, 24 bytes
last: "network down!"
```

Every call to `write` is a direct call.

Nothing is looked up at runtime, so the optimizer is free to inline `write` into the loop.

This is how generic code works in Zig.

[Comptime](https://www.ziglang.in/learn/language-basics/comptime/) shows the `comptime T: type` form.

`anytype` is the same idea, with the type taken from the argument instead of passed by hand.

The standard library uses it everywhere.

`std.mem.sort` takes its `context` as `anytype`, and so do most functions that accept a callback.

### Give the caller a better error

Pass an integer to `sendAll` without the first line, and the error points at `target.write` inside `sendAll`.

The person who made the mistake has to read your function to find out what it wanted.

`requireSink` runs first and says it in words:

<SnippetSource name="02-language.interfaces" decl="requireSink" />

`std.meta.hasMethod` looks through one pointer, so `*Counter` passes and `*u32` fails.

Now the build stops with `*u32 is not a sink: it has no write method`.

`@compileError` stops the build.

It does not return an error value, and nothing about it reaches the running program.

### Where `anytype` runs out

You can't put a `Counter` and a `Last` in the same array.

No type means "any sink", so there's nothing to declare the array as.

Each new type also compiles another copy of the function.

For a three-line loop that costs nothing you could measure.

For a large function called with many types, it grows the binary.

## 2. A tagged union: a closed list

<SnippetSource name="02-language.interfaces" decl="AnySink" />

`AnySink` is one type.

That means an array can hold both kinds of sink.

`inline else` makes the compiler write one prong per field.

Inside each prong, `s` has the real type, so `s.write` is a direct call again.

```
-- tagged union
counter: 3 lines
last: "network down!"
```

The list of implementations is closed.

A new kind of sink needs a new field in `AnySink`, and only the code that owns `AnySink` can add one.

Often that's exactly right.

The tokens of a parser, the instructions of a small VM and the values in a JSON document are all fixed lists.

`std.json.Value` is a `union(enum)` for that reason.

An `AnySink` is as large as its largest member, plus the tag.

`Last` carries a 32-byte buffer, so every `AnySink` pays for it, including the ones that hold a `Counter`.

[Unions](https://www.ziglang.in/learn/language-basics/unions/) covers the type itself.

## 3. A pointer and a vtable: an open list

<SnippetSource name="02-language.interfaces" decl="Sink" />

A `Sink` holds two things.

`ptr` points at the real object.

`vtable` points at a table of functions that know what to do with it.

`*anyopaque` is a pointer to something of unknown type.

The `Sink` doesn't know what it points at, and it doesn't need to.

Each implementation supplies the table and a way to make a `Sink` from itself:

<SnippetSource name="02-language.interfaces" decl="Counter" />

`writeOpaque` gets the `*anyopaque`, casts it back to `*Counter`, and calls the real `write`.

The cast is correct only because `sink()` stored a `*Counter` in `ptr`.

The compiler can't check that for you.

If one type's table ended up paired with another type's pointer, the cast would still compile.

`vtable` is a `const` declared in the struct, not a field.

It exists once in the program, and every `Sink` made from a `Counter` points at the same table.

Now two unrelated types fit in one array:

```
-- vtable
counter: 3 lines
last: "network down!"
a Sink is two pointers: true
```

This is the shape of `std.mem.Allocator`.

Open its source and the first two fields are `ptr: *anyopaque` and `vtable: *const VTable`.

`std.Io` is built the same way, with its pointer named `userdata`.

That's why an `ArenaAllocator` and a `SafeAllocator` can both be passed where an `Allocator` is wanted.

A library you have never seen can also add its own allocator without changing `std`.

The list is open.

Every call goes through a function pointer, and the optimizer usually can't inline through one.

The `Sink` also doesn't own the object.

If `counter2` goes out of scope while a `Sink` still points at it, `ptr` dangles.

The table holds pointers rather than the `Sink` holding them itself.

That keeps a `Sink` at two pointers however many methods the interface grows, because one table serves every `Counter` there is.

## 4. An embedded interface: `@fieldParentPtr`

`std.Io.Writer` goes one step further.

The interface isn't a separate value pointing at the object.

It's a field inside the object.

<SnippetSource name="02-language.interfaces" decl="Out" />

<SnippetSource name="02-language.interfaces" decl="Shouter" />

The vtable function receives a `*Out`.

That pointer points at the `interface` field inside some `Shouter`.

`@fieldParentPtr("interface", out)` subtracts the field's offset from that address and gives back the `*Shouter` around it.

There's no `*anyopaque` and no stored pointer back to the parent.

```
-- embedded
shouted: 1
```

The gain is that the interface can hold state of its own.

`std.Io.Writer` keeps its buffer in the interface.

`print` fills that buffer with ordinary code and calls through the vtable only when the buffer is full or you call `flush`.

Most writes never make an indirect call at all.

You have already used this shape.

Every program on this site writes `const out = &file_writer.interface;` before it prints anything.

The `&` matters.

`@fieldParentPtr` works only while the interface is still inside its parent.

Copy it out with `var copy = file_writer.interface;` and the vtable function subtracts the offset from the copy's address instead.

It lands on memory that isn't a `File.Writer`.

That compiles, and a safe build doesn't catch it.

When we tried it on `Shouter`, a `ReleaseSafe` build ran without a panic and printed `shouted: 0`.

It's undefined behaviour, so another build could do something worse.

Take the address of an embedded interface. Don't copy it.

[Linked lists in std](https://www.ziglang.in/learn/data-structures/std-lists/) use the same builtin for a different job: finding your struct from the list node inside it.

## Picking one

| Shape | Who can add an implementation | How `write` is called | One array of mixed types | In `std` |
| --- | --- | --- | --- | --- |
| `anytype` | anyone | directly, can inline | no | `std.mem.sort`'s `context` |
| tagged union | only the union's owner | switch, then directly | yes | `std.json.Value` |
| pointer and vtable | anyone | through a pointer | yes | `std.mem.Allocator`, `std.Io` |
| embedded interface | anyone | through a pointer, often skipped | yes, as pointers | `std.Io.Writer`, `std.Io.Reader` |

Start with `anytype`.

It's the least code and the fastest call.

Switch to a tagged union when you need a mixed list and you own every type in it.

Switch to a vtable when code you don't control has to plug in.

The embedded form is worth its extra rules only when the interface has state of its own, the way a writer has its buffer.

## If you have used other languages

Rust's generics with trait bounds do the job of `anytype`, and a Rust `enum` is a tagged union.

A Rust `&dyn Trait` is a data pointer and a vtable pointer, the same pair `Sink` holds.

A Go interface value is also two words: one points at the type's method table and the other at the data.

The difference in Zig is that you write the table yourself.
