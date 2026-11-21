# Reject Bad Input with @compileError

> Check the type that a generic function receives, and stop the build with a message that names the problem.

A generic function accepts `anytype`. Thus a caller can give it a type that the function cannot use. The compiler always finds this mistake, but the error message can be bad. It often points at a line inside the function, not at the call.

`@compileError("text")` stops the build with your text. Put it in a branch that the compiler reaches only for a bad type. Then the user of the function reads a message about their call.

```zig
const std = @import("std");

// The item type of an array, a slice or a pointer to an array.
// Any other type stops the build with a message that names the type.
fn Item(comptime T: type) type {
    const I = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            .one => switch (@typeInfo(info.child)) {
                .array => |array| array.child,
                else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
            },
            else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
        },
        else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
    };
    switch (@typeInfo(I)) {
        .int, .float => {},
        else => @compileError(std.fmt.comptimePrint(
            "sum: the items of {s} are {s}, not numbers",
            .{ @typeName(T), @typeName(I) },
        )),
    }
    return I;
}

fn sum(values: anytype) Item(@TypeOf(values)) {
    var total: Item(@TypeOf(values)) = 0;
    for (values) |v| total += v;
    return total;
}

// A function that needs a method. The check runs before the body, thus
// the message names the method that the type does not have, not a line inside the loop.
fn describeAll(out: *std.Io.Writer, items: anytype) !void {
    const T = @typeInfo(@TypeOf(items)).pointer.child;
    const E = @typeInfo(T).array.child;
    if (!@hasDecl(E, "describe")) {
        @compileError(@typeName(E) ++ " needs a `pub fn describe`");
    }
    for (items) |item| try item.describe(out);
}

const Dog = struct {
    name: []const u8,
    pub fn describe(self: Dog, out: *std.Io.Writer) !void {
        try out.print("  dog {s}\n", .{self.name});
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const bytes = [_]u8{ 10, 20, 30 };
    const prices = [_]f64{ 1.5, 2.25 };
    const prices_slice: []const f64 = &prices;
    try out.print("sum(array of u8) = {d}\n", .{sum(bytes)});
    try out.print("sum(&array of u8) = {d}\n", .{sum(&bytes)});
    try out.print("sum(slice of f64) = {d}\n", .{sum(prices_slice)});

    // `comptimePrint` formats during compilation. The result is a string
    // constant, the same kind of value as a literal.
    const label = comptime std.fmt.comptimePrint("{d} dogs", .{2});
    try out.print("{s}:\n", .{label});
    const dogs = [_]Dog{ .{ .name = "Moti" }, .{ .name = "Raja" } };
    try describeAll(out, &dogs);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.compile-error`)*

## The same mistake, two messages

`sum` adds the items of an array or a slice. The two programs below call `sum` with a list of strings. The first `sum` has no check:

```zig
const std = @import("std");

fn sum(values: anytype) @typeInfo(@TypeOf(values)).array.child {
    var total: @typeInfo(@TypeOf(values)).array.child = 0;
    for (values) |v| total += v;
    return total;
}

pub fn main() void {
    const names = [_][]const u8{ "Moti", "Raja" };
    std.debug.print("{any}\n", .{sum(names)});
}
```

The compiler says:

```
error: expected type '[]const u8', found 'comptime_int'
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.sum-unguarded`)*

The message is correct, but it does not help. It points at `total += v` inside `sum`, and it talks about a `comptime_int`. The caller did not write that line, and the caller did not use a `comptime_int`. The `0` that sets the start value of `total` is the `comptime_int`.

The second `sum` checks the type first:

```zig
const std = @import("std");

fn Item(comptime T: type) type {
    const I = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
        },
        else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
    };
    switch (@typeInfo(I)) {
        .int, .float => {},
        else => @compileError(std.fmt.comptimePrint(
            "sum: the items of {s} are {s}, not numbers",
            .{ @typeName(T), @typeName(I) },
        )),
    }
    return I;
}

fn sum(values: anytype) Item(@TypeOf(values)) {
    var total: Item(@TypeOf(values)) = 0;
    for (values) |v| total += v;
    return total;
}

pub fn main() void {
    const names = [_][]const u8{ "Moti", "Raja" };
    std.debug.print("{any}\n", .{sum(names)});
}
```

The compiler says:

```
error: sum: the items of [2][]const u8 are []const u8, not numbers
note: generic function instantiated here
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.sum-guarded`)*

The message names the argument type and the item type, and it says what is wrong. The note `generic function instantiated here` points at the call in `main`. That is the line that the caller must change.

## The check

```zig
fn Item(comptime T: type) type {
    const I = switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) { ... },
        else => @compileError("sum: expected an array or a slice, found " ++ @typeName(T)),
    };
    switch (@typeInfo(I)) {
        .int, .float => {},
        else => @compileError(std.fmt.comptimePrint(
            "sum: the items of {s} are {s}, not numbers",
            .{ @typeName(T), @typeName(I) },
        )),
    }
    return I;
}
```

`Item` returns the item type of `T`, or it stops the build. `sum` uses `Item` in its return type:

```zig
fn sum(values: anytype) Item(@TypeOf(values)) {
```

The compiler calculates the return type before it reads the body. Thus the check runs first, and the body never sees a bad type.

The check accepts three shapes: an array, a slice and a pointer to an array. The output shows all three:

```
sum(array of u8) = 60
sum(&array of u8) = 60
sum(slice of f64) = 3.75
```

## The message is a comptime string

`@compileError` takes a comptime-known string. There are two ways to build one:

- `++` joins strings that are comptime-known. `@typeName(T)` returns one.
- `std.fmt.comptimePrint` formats a string with the same syntax as `print`. Use it when the message contains a number, or when it has many parts.

`comptimePrint` is not only for errors. The program uses it to make the label `2 dogs` during compilation.

## Check for a method

```zig
if (!@hasDecl(E, "describe")) {
    @compileError(@typeName(E) ++ " needs a `pub fn describe`");
}
```

`describeAll` calls `describe` on each item. Without the check, a type with no `describe` method gives the error `no field or member function named 'describe'`. That error points at the line in the loop. With the check, the message says what the type must have.

`@hasDecl` sees only `pub` declarations. Thus the message says `pub fn`, and a method without `pub` fails the check.

[Interfaces](https://www.ziglang.in/learn/language-basics/interfaces/) shows other ways to give a generic function an interface.

## When to add a check

Do not check each generic function. The compiler finds each type error without your help. Add a check when one of these conditions is true:

- Other people call the function, for example in a library.
- The error without a check points deep inside your code.
- The rule is not visible in the code, for example "the items must be numbers".

## Check yourself

`sum("abc")` calls `sum` with a string literal. Does the build stop?

No. The type of `"abc"` is `*const [3:0]u8`, a pointer to an array. `Item` accepts a pointer to an array, and the items are `u8`, an integer. Thus `sum("abc")` returns 97 + 98 + 99. That sum is 294, and it does not fit in a `u8`. In a build with safety checks, the program stops with an integer overflow.

A check accepts what its rules accept. If the function must refuse strings, the rules must say so.
