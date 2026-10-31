# Know the Limits

> What comptime code cannot do, what to use instead, and what comptime costs.

Comptime code is usual Zig, but it runs inside the compiler. The compiler has no program, no operating system and no heap for that code. Thus some functions that work at runtime do not work during compilation.

This chapter gives the limits, and the tool to use for each one.

```zig
const std = @import("std");

// Comptime code cannot open a file. `@embedFile` is the exception: the
// compiler reads the file and the bytes become a string constant.
const colors_txt = @embedFile("colors.txt");

// `parseColors` calls this function in its return type, before the quota
// line in its own body runs. Thus this function sets its own quota.
fn lineCount(comptime text: []const u8) usize {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}

const Entry = struct { []const u8, u24 };

// Parse "name=rrggbb" lines into key and value pairs. There is no runtime
// allocator at comptime, thus the result is an array with a size that
// the compiler calculates.
fn parseColors(comptime text: []const u8) [lineCount(text)]Entry {
    @setEvalBranchQuota(100_000);
    var entries: [lineCount(text)]Entry = undefined;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    for (&entries) |*entry| {
        const line = it.next().?;
        const eq = std.mem.findScalar(u8, line, '=') orelse
            @compileError("colors.txt: no '=' in line: " ++ line);
        const value = std.fmt.parseInt(u24, line[eq + 1 ..], 16) catch
            @compileError("colors.txt: bad hex in line: " ++ line);
        entry.* = .{ line[0..eq], value };
    }
    return entries;
}

const colors = std.StaticStringMap(u24).initComptime(parseColors(colors_txt));

// Strings join with `++` during compilation. The result has a length
// that the compiler knows.
const names = blk: {
    var joined: []const u8 = "";
    for (parseColors(colors_txt), 0..) |entry, i| {
        joined = joined ++ (if (i == 0) "" else ", ") ++ entry[0];
    }
    break :blk joined;
};

fn List(comptime T: type) type {
    return struct { items: []T };
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("1. colors.txt: {d} bytes, {d} colors\n", .{ colors_txt.len, colors.keys().len });
    for ([_][]const u8{ "saffron", "blue", "purple" }) |name| {
        if (colors.get(name)) |rgb| {
            try out.print("   {s} = #{x:0>6}\n", .{ name, rgb });
        } else {
            try out.print("   {s}: not in the file\n", .{name});
        }
    }

    try out.print("2. names: {s} ({d} bytes)\n", .{ names, names.len });

    // The compiler keeps one result for each set of comptime arguments.
    // The same arguments give the same type. New arguments give a new copy.
    try out.print("3. List(u8) == List(u8): {}\n", .{List(u8) == List(u8)});
    try out.print("   List(u8) == List(u16): {}\n", .{List(u8) == List(u16)});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.limits`)*

## No runtime allocator

An `ArrayList` needs an allocator, and an allocator asks the operating system for memory. During compilation, there is no operating system to ask:

```zig
const std = @import("std");

const count = blk: {
    var list: std.ArrayList(u8) = .empty;
    list.append(std.heap.page_allocator, 1) catch unreachable;
    break :blk list.items.len;
};

pub fn main() void {
    std.debug.print("{d}\n", .{count});
}
```

The compiler says:

```
error: unable to resolve comptime value
note: called at comptime from here
```

*Compiled by CI, but not runnable in the browser sandbox. (`25-comptime.comptime-alloc`)*

The error points inside the standard library, at the place where the allocator asks for memory. The notes `called at comptime from here` lead back to the `append` call.

Use these tools instead:

- An array with a length that a comptime function calculates. [Parse Strings at Compile Time](https://www.ziglang.in/learn/metaprogramming/parse-strings/) uses this method.
- A `comptime var` of type `[]const u8`, extended with `++`.

The program joins the color names with `++`:

```
2. names: red, green, blue, saffron (25 bytes)
```

Each `++` makes a new comptime string, with a length that the compiler knows.

## No I/O, except `@embedFile`

Comptime code cannot open a file, read the clock or call the network. A build that reads the clock would give a different binary each time.

`@embedFile("colors.txt")` is the exception. The compiler reads the file and makes its bytes a string constant. The path is relative to the source file. The compiler notes the file as an input, thus a change to the file starts a new build.

The program parses the file during compilation:

```zig
const colors = std.StaticStringMap(u24).initComptime(parseColors(colors_txt));
```

`parseColors` splits the lines and parses each hex value. A line without `=`, or with a bad hex value, stops the build with `@compileError`. `StaticStringMap.initComptime` then builds a lookup structure from the pairs.

```
1. colors.txt: 51 bytes, 4 colors
   saffron = #f4c430
   blue = #0000ff
   purple: not in the file
```

The binary contains the map, not the text parser. The page runs this program in your browser, and the browser has no `colors.txt`. The program does not need the file at runtime.

## The branch quota

`parseColors` and `lineCount` both start with `@setEvalBranchQuota(100_000)`. The default limit is 1000 backward branches, and a file of 20 lines already needs more.

`lineCount` needs its own quota. `parseColors` calls `lineCount` in its return type, and the compiler calculates the return type before the body of `parseColors` runs. Thus the quota line in that body does not cover `lineCount`.

The branch count is difficult to calculate here. The tokenizer, `parseInt` and `initComptime` all add branches. Thus measure: make the file larger until the build fails. On 2026-10-24, this program built with a file of 400 lines.

[Build Lookup Tables](https://www.ziglang.in/learn/metaprogramming/lookup-tables/) shows the error when a loop is longer than the limit, and how to calculate the limit from the loops.

## One copy for each set of arguments

```
3. List(u8) == List(u8): true
   List(u8) == List(u16): false
```

The compiler keeps the result of each comptime call. A second call with the same arguments returns the same type, and the compiler does no work again. A call with new arguments makes a new type, with new copies of each function that the program uses.

Each copy adds machine code to the binary. Each comptime calculation adds time to each build. The two costs grow with the number of different arguments:

- `List(u8)`, `List(u16)` and `List(Point)` give three copies. The cost is small.
- A `comptime` parameter that gets a different value for each call site can give hundreds of copies. Change it to a runtime parameter.

## Comptime cannot see runtime values

A comptime calculation cannot read a value that exists only at runtime. [Know What the Compiler Knows](https://www.ziglang.in/learn/metaprogramming/compiler-knows/) shows the error for a `var` that sets an array length. The fix is always one of two:

- Make the value comptime-known.
- Move the calculation to runtime.

## Check yourself

`colors.txt` gets a fifth line, `teal=008080`. Which steps run again?

The compiler sees that an input changed and builds again. `parseColors` runs again during that build, and `initComptime` builds a new map with five pairs. The program code does not change. At runtime, the program only reads the new map.
