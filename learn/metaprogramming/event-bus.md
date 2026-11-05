# Project: A Typed Event Bus

> Handlers are plain functions. The bus reads their parameter types and connects each one to its event during compilation.

An event bus delivers each event to the functions that want it. In many languages, a handler registers with a string name, and the bus calls it at runtime with an untyped value. A misspelled name or a wrong type shows only when the event arrives.

In this project, a handler is a plain function, and its parameter type says which event it wants. The bus reads the parameter types during compilation. Thus a handler for an event that does not exist stops the build.

The project uses three earlier chapters:

- [Read a Type](https://www.ziglang.in/learn/metaprogramming/read-a-type/), to read the parameter types of a function.
- [Dispatch with Comptime](https://www.ziglang.in/learn/metaprogramming/dispatch/), for `inline else`.
- [Reject Bad Input with @compileError](https://www.ziglang.in/learn/metaprogramming/compile-error/), for the message.

```zig
const std = @import("std");
const Writer = std.Io.Writer;

const Click = struct { x: i32, y: i32 };
const Key = struct { code: u8 };
const Resize = struct { width: u32, height: u32 };

const Event = union(enum) {
    click: Click,
    key: Key,
    resize: Resize,
};

// The payload type that a handler accepts: its second parameter.
fn Payload(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.param_types.len != 2) @compileError("a handler takes (*Writer, payload)");
    return info.param_types[1].?;
}

fn Bus(comptime E: type, comptime handlers: anytype) type {
    const variants = @typeInfo(E).@"union";
    // Each handler must accept the payload of one variant. A check here
    // gives one clear message, before any event exists.
    for (handlers, 0..) |handler, i| {
        const P = Payload(handler);
        for (variants.field_types) |V| {
            if (V == P) break;
        } else @compileError(std.fmt.comptimePrint(
            "handler {d} takes {s}, which is not a payload of {s}",
            .{ i, @typeName(P), @typeName(E) },
        ));
    }

    return struct {
        // The number of handlers for each variant, counted by the compiler.
        pub fn count(comptime tag: std.meta.Tag(E)) usize {
            var n: usize = 0;
            for (handlers) |handler| {
                if (Payload(handler) == @FieldType(E, @tagName(tag))) n += 1;
            }
            return n;
        }

        // One branch for each variant. Each branch calls only the handlers
        // for that variant, directly, in the order of the list.
        pub fn emit(out: *Writer, event: E) !void {
            switch (event) {
                inline else => |payload| {
                    inline for (handlers) |handler| {
                        if (comptime Payload(handler) == @TypeOf(payload)) {
                            try handler(out, payload);
                        }
                    }
                },
            }
        }
    };
}

var keys_pressed: usize = 0;

fn logClick(out: *Writer, c: Click) !void {
    try out.print("  logClick: ({d}, {d})\n", .{ c.x, c.y });
}

fn countKey(out: *Writer, k: Key) !void {
    keys_pressed += 1;
    try out.print("  countKey: code {d}, {d} so far\n", .{ k.code, keys_pressed });
}

fn quitOnEscape(out: *Writer, k: Key) !void {
    if (k.code == 27) try out.print("  quitOnEscape: escape, quit\n", .{});
}

const UiBus = Bus(Event, .{ logClick, countKey, quitOnEscape });

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    inline for (.{ .click, .key, .resize }) |tag| {
        try out.print("handlers for .{s}: {d}\n", .{ @tagName(tag), comptime UiBus.count(tag) });
    }

    const events = [_]Event{
        .{ .click = .{ .x = 10, .y = 20 } },
        .{ .key = .{ .code = 65 } },
        .{ .resize = .{ .width = 800, .height = 600 } },
        .{ .key = .{ .code = 27 } },
    };
    for (events) |event| {
        try out.print("emit .{t}\n", .{event});
        try UiBus.emit(out, event);
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.event-bus`)*

## Events and handlers

```zig
const Event = union(enum) {
    click: Click,
    key: Key,
    resize: Resize,
};

fn logClick(out: *Writer, c: Click) !void { ... }
fn countKey(out: *Writer, k: Key) !void { ... }
fn quitOnEscape(out: *Writer, k: Key) !void { ... }

const UiBus = Bus(Event, .{ logClick, countKey, quitOnEscape });
```

Each variant of `Event` has its own payload type. Each handler takes a writer and one payload type. The list of handlers is a tuple of functions, and it is a `comptime` argument to `Bus`.

## Read the payload type of a handler

```zig
fn Payload(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.param_types.len != 2) @compileError("a handler takes (*Writer, payload)");
    return info.param_types[1].?;
}
```

The type of a function is a usual type, and `@typeInfo` describes it. `param_types` is a list of the parameter types. Each item is optional, because a parameter of a generic function has no fixed type. Here, the `.?` stops the build if the second parameter is `anytype`.

## Check each handler

```zig
for (handlers, 0..) |handler, i| {
    const P = Payload(handler);
    for (variants.field_types) |V| {
        if (V == P) break;
    } else @compileError(std.fmt.comptimePrint(
        "handler {d} takes {s}, which is not a payload of {s}",
        .{ i, @typeName(P), @typeName(E) },
    ));
}
```

The check runs when the compiler evaluates `Bus(...)`. The `else` of a `for` runs when the loop ends without a `break`. Thus the error occurs only when no variant has the payload type of the handler.

Give the bus a handler for a `Scroll` event, which `Event` does not have:

```zig
const std = @import("std");
const Writer = std.Io.Writer;

const Click = struct { x: i32, y: i32 };
const Key = struct { code: u8 };
const Resize = struct { width: u32, height: u32 };

const Event = union(enum) {
    click: Click,
    key: Key,
    resize: Resize,
};

// The payload type that a handler accepts: its second parameter.
fn Payload(comptime handler: anytype) type {
    const info = @typeInfo(@TypeOf(handler)).@"fn";
    if (info.param_types.len != 2) @compileError("a handler takes (*Writer, payload)");
    return info.param_types[1].?;
}

fn Bus(comptime E: type, comptime handlers: anytype) type {
    const variants = @typeInfo(E).@"union";
    // Each handler must accept the payload of one variant. A check here
    // gives one clear message, before any event exists.
    for (handlers, 0..) |handler, i| {
        const P = Payload(handler);
        for (variants.field_types) |V| {
            if (V == P) break;
        } else @compileError(std.fmt.comptimePrint(
            "handler {d} takes {s}, which is not a payload of {s}",
            .{ i, @typeName(P), @typeName(E) },
        ));
    }

    return struct {
        // The number of handlers for each variant, counted by the compiler.
        pub fn count(comptime tag: std.meta.Tag(E)) usize {
            var n: usize = 0;
            for (handlers) |handler| {
                if (Payload(handler) == @FieldType(E, @tagName(tag))) n += 1;
            }
            return n;
        }

        // One branch for each variant. Each branch calls only the handlers
        // for that variant, directly, in the order of the list.
        pub fn emit(out: *Writer, event: E) !void {
            switch (event) {
                inline else => |payload| {
                    inline for (handlers) |handler| {
                        if (comptime Payload(handler) == @TypeOf(payload)) {
                            try handler(out, payload);
                        }
                    }
                },
            }
        }
    };
}

const Scroll = struct { dy: i32 };

fn logClick(out: *Writer, c: Click) !void {
    try out.print("click ({d}, {d})\n", .{ c.x, c.y });
}

fn logScroll(out: *Writer, s: Scroll) !void {
    try out.print("scroll {d}\n", .{s.dy});
}

const UiBus = Bus(Event, .{ logClick, logScroll });

pub fn main() void {
    std.debug.print("{d}\n", .{UiBus.count(.click)});
}
```

The compiler says:

```
error: handler 1 takes event-bus-wrong.Scroll, which is not a payload of event-bus-wrong.Event
note: called at comptime here
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.event-bus-wrong`)*

`handler 1` is the second item of the tuple, because the count starts at 0. The note `called at comptime here` points at the line that makes the bus.

## Deliver an event

```zig
pub fn emit(out: *Writer, event: E) !void {
    switch (event) {
        inline else => |payload| {
            inline for (handlers) |handler| {
                if (comptime Payload(handler) == @TypeOf(payload)) {
                    try handler(out, payload);
                }
            }
        },
    }
}
```

`inline else` makes one branch for each variant. In each branch, the `inline for` checks each handler, and the `if` is comptime-known. Thus each branch contains only the calls for its variant. The branch for `.key` contains two direct calls, in the order of the list. The branch for `.resize` contains no calls:

```
emit .key
  countKey: code 65, 1 so far
emit .resize
emit .key
  countKey: code 27, 2 so far
  quitOnEscape: escape, quit
```

At runtime, `emit` is one `switch` and some direct calls. There is no list of function pointers and no lookup by name.

## Count the handlers

```
handlers for .click: 1
handlers for .key: 2
handlers for .resize: 0
```

`count` runs during compilation. A program can use it in a test, for example to require at least one handler for each event. Then a new variant in `Event` without a handler stops the test.

## Limits of this design

- The program cannot change the list of handlers after it compiles. A plugin that registers a handler at runtime needs a list of function pointers.
- Two variants with the same payload type, for example `key_down: Key` and `key_up: Key`, cannot have different handlers. `Payload` connects a handler to a type, not to a variant. To separate them, give each variant its own payload type.
- Handlers share the writer and nothing else. A handler that needs state, such as `countKey`, uses a global variable here. A real bus passes a context pointer.

## Check yourself

Add the variant `scroll: Scroll` to `Event`, and do not add a handler. Does the program still compile?

Yes. The check requires each handler to match a variant. It does not require each variant to have a handler. `emit` makes a branch for `.scroll` with no calls, and `count(.scroll)` returns 0.
