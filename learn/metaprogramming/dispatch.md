# Dispatch with Comptime

> Connect each tag of an enum to its handler at compile time, with a switch or with a table.

A program that reads commands must connect each command to the code for that command. The name of this connection is dispatch.

In Zig, the commands are often the tags of an enum. The compiler knows each tag, thus it can make the connection during compilation. If a tag has no handler, the build stops.

The program below reads five commands from a script. It connects each command to its handler in two ways, and the two results must agree.

```zig
const std = @import("std");

const Op = enum { add, sub, mul, neg };

// One function for each tag of `Op`, with the same name as the tag.
const Handlers = struct {
    pub fn add(a: i64, b: i64) i64 {
        return a + b;
    }
    pub fn sub(a: i64, b: i64) i64 {
        return a - b;
    }
    pub fn mul(a: i64, b: i64) i64 {
        return a * b;
    }
    pub fn neg(a: i64, _: i64) i64 {
        return -a;
    }
};

// 1. A switch with `inline else`. The compiler makes one branch for each
//    tag, and each branch calls its handler directly.
fn runSwitch(op: Op, a: i64, b: i64) i64 {
    return switch (op) {
        inline else => |tag| @field(Handlers, @tagName(tag))(a, b),
    };
}

// 2. A table of function pointers, built during compilation.
//    The program indexes it with the tag at runtime.
const Handler = *const fn (i64, i64) i64;
const table: std.EnumArray(Op, Handler) = blk: {
    var t: std.EnumArray(Op, Handler) = undefined;
    for (std.enums.values(Op)) |tag| {
        t.set(tag, @field(Handlers, @tagName(tag)));
    }
    break :blk t;
};

fn runTable(op: Op, a: i64, b: i64) i64 {
    return table.get(op)(a, b);
}

// 3. Data for each tag, in a table that the compiler checks: an
//    `EnumArray` must have a value for each tag.
const symbols: std.EnumArray(Op, []const u8) = .init(.{
    .add = "+",
    .sub = "-",
    .mul = "*",
    .neg = "neg",
});

const script =
    \\add 2 3
    \\mul 4 5
    \\neg 7 0
    \\sub 10 4
    \\div 8 2
;

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse continue;
        const a = try std.fmt.parseInt(i64, words.next().?, 10);
        const b = try std.fmt.parseInt(i64, words.next().?, 10);

        // `stringToEnum` compares the text with each tag name. The
        // compiler makes the list of names from `Op`.
        const op = std.meta.stringToEnum(Op, name) orelse {
            try out.print("{s}: unknown command\n", .{name});
            continue;
        };
        const by_switch = runSwitch(op, a, b);
        const by_table = runTable(op, a, b);
        try out.print("{s} {d} {d} = {d} (switch), {d} (table), symbol {s}\n", .{
            name, a, b, by_switch, by_table, symbols.get(op),
        });
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.dispatch`)*

## Handlers with the same names as the tags

```zig
const Op = enum { add, sub, mul, neg };

const Handlers = struct {
    pub fn add(a: i64, b: i64) i64 { ... }
    pub fn sub(a: i64, b: i64) i64 { ... }
    pub fn mul(a: i64, b: i64) i64 { ... }
    pub fn neg(a: i64, _: i64) i64 { ... }
};
```

`Handlers` is a struct with no fields. It is a namespace for four functions. Each function has the same name as one tag of `Op`. The program uses this rule to find the handler for a tag.

## Dispatch with `inline else`

```zig
fn runSwitch(op: Op, a: i64, b: i64) i64 {
    return switch (op) {
        inline else => |tag| @field(Handlers, @tagName(tag))(a, b),
    };
}
```

`inline else` makes one branch for each tag. In each branch, `tag` is comptime-known. Thus `@tagName(tag)` is a comptime-known string, and `@field(Handlers, "add")` finds the function `Handlers.add`.

The compiler then has four usual branches, and each branch calls one function directly. The result is the same as a `switch` that you write by hand, with one line for each tag.

## Dispatch with a table

```zig
const Handler = *const fn (i64, i64) i64;
const table: std.EnumArray(Op, Handler) = blk: {
    var t: std.EnumArray(Op, Handler) = undefined;
    for (std.enums.values(Op)) |tag| {
        t.set(tag, @field(Handlers, @tagName(tag)));
    }
    break :blk t;
};
```

`std.EnumArray(Op, Handler)` is an array with one item for each tag of `Op`. The block fills it during compilation, with the address of each handler. At runtime, `table.get(op)` reads one item and calls the function at that address.

The two methods give the same results:

```
add 2 3 = 5 (switch), 5 (table), symbol +
mul 4 5 = 20 (switch), 20 (table), symbol *
neg 7 0 = -7 (switch), -7 (table), symbol neg
sub 10 4 = 6 (switch), 6 (table), symbol -
```

Select one method with these rules:

- Use `inline else` when the set of handlers does not change at runtime. Each call is direct, and the compiler can inline the handler.
- Use a table when the program must change a handler at runtime, or when it must keep the handlers in data.

## Data for each tag

```zig
const symbols: std.EnumArray(Op, []const u8) = .init(.{
    .add = "+",
    .sub = "-",
    .mul = "*",
    .neg = "neg",
});
```

`.init` takes a struct with one field for each tag. If the struct has no field for one tag, the compiler stops with the error `missing struct field`. Thus a table of data cannot become shorter than the enum.

## From a string to a tag

The script contains text, not tags. `std.meta.stringToEnum(Op, name)` compares the text with each tag name. It returns `null` when no tag has that name:

```
div: unknown command
```

`stringToEnum` is a usual generic function. The compiler makes the list of names from `Op`, thus the list always agrees with the enum.

## A new tag without a handler

Add a `div` tag to `Op`, and do not add a `div` function to `Handlers`:

```zig
const std = @import("std");

const Op = enum { add, neg, div };

const Handlers = struct {
    pub fn add(a: i64, b: i64) i64 {
        return a + b;
    }
    pub fn neg(a: i64, _: i64) i64 {
        return -a;
    }
};

fn run(op: Op, a: i64, b: i64) i64 {
    return switch (op) {
        inline else => |tag| @field(Handlers, @tagName(tag))(a, b),
    };
}

pub fn main() void {
    std.debug.print("{d}\n", .{run(.add, 2, 3)});
}
```

The compiler says:

```
error: struct 'dispatch-new-tag.Handlers' has no member named 'div'
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.dispatch-new-tag`)*

The `inline else` branch for `div` asks for `Handlers.div`, and that function does not exist. The build stops before the program can receive a `div` command. In the full program, the table and `symbols` also stop the build, each with its own error.

Without comptime, the same mistake gives a different result. A `switch` with an `else` branch accepts `div` and does the wrong thing at runtime.

## Check yourself

`runSwitch` has no `else` branch for unknown tags. Why does it not need one?

`op` has the type `Op`, and `inline else` makes a branch for each tag of `Op`. Thus the `switch` handles each possible value. An unknown command never reaches `runSwitch`: `stringToEnum` returns `null` for it first.
