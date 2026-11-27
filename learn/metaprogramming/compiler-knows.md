# Know What the Compiler Knows

> The rule that decides which values the compiler can use, and four ways to use them.

Each value in a Zig program is one of two kinds:

- A **comptime-known** value is a value that the compiler knows during compilation.
- A **runtime-known** value is a value that only the program knows when it runs.

Some places in the language accept only comptime-known values. An array length, a type and a `comptime` parameter are three of these places. Thus you must know which kind each value is.

[Comptime](https://www.ziglang.in/learn/language-basics/comptime/) in Language Basics gives the idea in one page. This section starts at that point.

```zig
const std = @import("std");

fn square(x: u32) u32 {
    return x * x;
}

// A function does not decide where it runs. The caller decides.
// `@inComptime()` tells the function which case is true.
fn where() []const u8 {
    return if (@inComptime()) "compile time" else "runtime";
}

// A comptime parameter can be part of the return type.
// Each different `n` makes a different function.
fn repeat(comptime n: usize, char: u8) [n]u8 {
    return @splat(char);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // 1. A `const` with a literal value is comptime-known.
    //    A `var` is runtime-known, even when its value never changes.
    const width = 8;
    var height: u32 = 3;
    _ = &height;
    try out.print("1. width: {s}, height: {s}\n", .{ @typeName(@TypeOf(width)), @typeName(@TypeOf(height)) });

    // A comptime-known value can be an array length. `height` cannot.
    const row: [width]u8 = @splat('#');
    try out.print("   row: {s}\n", .{&row});

    // 2. The same function, called two ways.
    const at_compile = comptime where();
    const at_run = where();
    try out.print("2. comptime where(): {s}\n", .{at_compile});
    try out.print("   where(): {s}\n", .{at_run});

    // 3. A labelled block after `comptime` runs during compilation.
    //    The binary contains only the array, not the loop.
    const squares = comptime blk: {
        var table: [6]u32 = undefined;
        for (&table, 0..) |*slot, i| slot.* = square(@intCast(i));
        break :blk table;
    };
    try out.print("3. squares: {any}\n", .{squares});

    // 4. A comptime parameter sets the length of the result.
    const three = repeat(3, 'a');
    const five = repeat(5, 'b');
    try out.print("4. {s} is a {s}\n", .{ &three, @typeName(@TypeOf(three)) });
    try out.print("   {s} is a {s}\n", .{ &five, @typeName(@TypeOf(five)) });

    // 5. A `comptime var` lives only during compilation. An `inline for`
    //    runs its body once for each item, so the counter sees each one.
    const words = .{ "red", "green", "blue" };
    comptime var total = 0;
    inline for (words) |word| total += word.len;
    try out.print("5. letters in {d} words: {d}\n", .{ words.len, total });
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.compiler-knows`)*

## `const` and `var`

The first part of the program declares two values:

```zig
const width = 8;
var height: u32 = 3;
```

The output shows their types:

```
1. width: comptime_int, height: u32
```

`width` is a `const` with a literal value. The compiler knows the value, and the type is `comptime_int`. A `comptime_int` has no fixed size. It becomes a sized integer when you use it in a place that needs one.

`height` is a `var`. The program never changes it, but the compiler does not use that fact. A `var` is runtime-known, always.

A `const` is not always comptime-known. `const n = readNumber();` is a `const`, but the value comes from a function that runs when the program runs. The rule is about the source of the value, not about the keyword.

## A runtime value where a type must go

`width` is comptime-known, thus `[width]u8` is a valid type. The program uses it for a row of 8 characters.

The next program tries the same thing with a `var`:

```zig
const std = @import("std");

pub fn main() void {
    var n: usize = 4;
    _ = &n;
    // `n` never changes, but it is a `var`. Thus the compiler does not use
    // its value, and `[n]u8` is not a type that the compiler can make.
    const buf: [n]u8 = @splat(0);
    std.debug.print("{d}\n", .{buf.len});
}
```

The compiler says:

```
error: unable to resolve comptime value
note: types must be comptime-known
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.runtime-length`)*

The length of an array is part of its type, and the compiler must know each type. A `var` cannot supply a value to a type.

To repair the program, use one of these two changes:

- Change `var` to `const`, if the value is a literal.
- Use a slice from an allocator, if the length is only known at runtime.

## The caller decides where a function runs

`where` is a usual function. It has no `comptime` keyword in its declaration. The program calls it two times:

```
2. comptime where(): compile time
   where(): runtime
```

The `comptime` keyword before a call tells the compiler to run the call during compilation. Without the keyword, the call runs when the program runs. Thus one function can run at both times. The function itself does not decide.

`@inComptime()` returns `true` when the code runs during compilation. Use it only when a function must do different work in the two cases. Most functions do not need it.

If a call has `comptime` in front of it, the compiler must be able to run it. A function that reads a file or the clock cannot run during compilation. The compiler then stops with an error, and the program does not build.

## A `comptime` block

```zig
const squares = comptime blk: {
    var table: [6]u32 = undefined;
    for (&table, 0..) |*slot, i| slot.* = square(@intCast(i));
    break :blk table;
};
```

The block runs during compilation. The block can contain a `var`, and the loop changes the array six times. The result of the block is the array, and the binary contains only the six numbers:

```
3. squares: { 0, 1, 4, 9, 16, 25 }
```

The block uses `var` inside, but `squares` is a `const` with a comptime-known value. The block, not the `var`, decides the kind of the result.

## A `comptime` parameter in the return type

```zig
fn repeat(comptime n: usize, char: u8) [n]u8 {
    return @splat(char);
}
```

`n` is a `comptime` parameter. Thus the function can use `n` in its return type. Each call with a different `n` makes a separate copy of the function, and each copy has a different return type:

```
4. aaa is a [3]u8
   bbbbb is a [5]u8
```

`char` is a usual parameter. It can be a runtime value.

Each different value of `n` adds one copy to the binary. For a parameter with a small number of values, the cost is small. For a parameter with thousands of values, the binary becomes large.

## A `comptime var`

```zig
const words = .{ "red", "green", "blue" };
comptime var total = 0;
inline for (words) |word| total += word.len;
```

A `comptime var` exists only during compilation. The `inline for` runs its body one time for each word, and each copy of the body adds to the counter:

```
5. letters in 3 words: 12
```

A usual `for` cannot change a `comptime var`. The compiler compiles a usual loop body one time, and the body runs at runtime. A runtime loop cannot change a value that exists only during compilation. [Inline Loops](https://www.ziglang.in/learn/language-basics/inline-loops/) gives more examples of `inline for`.

## Check yourself

`const limit = std.math.maxInt(u8);` Is `limit` comptime-known?

Yes. `std.math.maxInt` is a usual function. Its argument is a type, and a type is always comptime-known. The result is the same each time, and the compiler calculates it during compilation. Thus `[limit]u8` is a valid array type of 255 bytes.

The next chapter uses a `comptime` block to make a lookup table, and checks the table against the standard library.
