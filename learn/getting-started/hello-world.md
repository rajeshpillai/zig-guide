# Hello World

> Your first Zig program, and the reason that main now takes an argument.

This is the shortest Zig program that prints text. It is almost the same as the first program in each older Zig tutorial. It still compiles on current master:

```zig
const std = @import("std");

// These four lines have two separate old habits: a `main` with no parameter,
// and output through `std.debug.print`. The two habits still work on current
// master, and each habit is independent of the other.
pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
```

*CI compiles this program against master each night, but this page does not run it. To follow the steps, save it as hello.zig. (`01-getting-started.older-main`)*

The four lines have two separate parts: the call that prints, and the signature of `main`. You can change one part and keep the other part.

A Run button on this site means that the browser sandbox can run the snippet. The Run button does not tell you which shape to prefer.

## When to use `std.debug.print`

`std.debug.print` needs no preparation and returns `void`. Thus you have no value to pass to other code and no error to handle. Use `std.debug.print` for lines that you will delete later. For example, use it to check that a loop runs, or to print a struct while you build a feature. You can use it as much as you like while you work.

Do not use `std.debug.print` for the output of a program. The first time that you use a shell, you will see the reason:

- stdout carries the data that a different program reads when you pipe this program into it.
- stderr carries the text for the person who runs the program.

The greeting above goes to **stderr**. Thus, if you redirect the program into a file, the file stays empty. To check, run `zig run hello.zig > out.txt`. The greeting prints to your terminal, and the program writes zero bytes to `out.txt`. The [standard streams](https://www.ziglang.in/learn/os/standard-streams/) chapter shows the two streams side by side.

There is a second reason. `std.debug.print` ends in `catch return`. If the write fails, the output is lost and the program does not know about the failure. For a temporary line, this behaviour is acceptable. For software that you ship, it is not acceptable.

Thus, use `std.debug.print` while you work. For the real output of the program, use a writer that the caller gives to your code. The other sections of this page use a writer of this type.

## Why `main` takes a parameter

The program above uses `pub fn main() !void`. On current Zig master, there is also a form that takes an argument:

```zig
pub fn main(init: std.process.Init) !void
```

`init.io` is an **`Io`**. An `Io` is a value that gives the ability to do input and output. To write to a file, open a socket or read the clock, you give an `Io` as an argument. Thus code cannot block or start a thread unless a caller gives it an `Io`. There is no global `stdout`. Your code can write only if a caller gives it an `Io`.

The program below prints the same greeting on stdout, through the `Io` that `main` received. Press **Run**. The program runs in your browser as WebAssembly.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.hello-world`)*

The caller selects the `Io` that it gives to `main`. The threaded implementation and the event-loop implementation are two of the choices. A later chapter, [the `Io` interface](https://www.ziglang.in/learn/standard-library/io-interface/), explains them.

Zig's `Allocator` uses the same design. The `Io` applies that design to I/O: the caller supplies the mechanism, and nothing occurs without your knowledge. If you do not know `Allocator` yet, you can ignore it on this page. [Allocators](https://www.ziglang.in/learn/standard-library/allocators/) is a later chapter, and nothing on this page needs it.

## Why `!void`, and when to remove the `!`

`void` means that `main` returns nothing. The `!` before `void` means that `main` can also return an error.

The greeting needs the `!` because of `try`. A write to stdout can fail. For example, the output can be a pipe that the other program closed, or a file on a full disk. In these conditions, `writeStreamingAll` returns an error.

`try` passes that error to the caller. The caller of `main` is the startup code of the program. Thus `main` must be able to return an error, and the `!` tells the compiler that it can.

When `main` returns an error, Zig prints the name of the error, for example `error: FileNotFound`. Then the program exits with status 1. A Debug build also prints the location where the error started. For a small program, this is an acceptable way to fail. Thus most examples use `!void`.

If you remove the `!` and keep the call, the program does not compile. Zig does not let you ignore an error. The compiler names the error set that the call can return. Then it tells you to use `try`, `catch` or `if`.

You can remove the `!` in two conditions:

1. Nothing in `main` can fail.
2. `main` handles each error itself, with `catch`.

For the first condition, look at `std.debug.print`. It returns plain `void`, thus the older program at the top of this page does not need `!void`. `pub fn main() void` compiles and prints the same text. Older tutorials write `!void` there because of habit.

For the second condition, look at this program:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) void {
    std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n") catch |err| {
        // If the return type has no `!`, handle each error here.
        std.debug.print("could not write the greeting: {t}\n", .{err});
        std.process.exit(1);
    };
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.main-void`)*

The `catch` block receives the error and prints a message that a person can read. Then it exits with status 1. Nothing remains for `main` to return, thus its return type is `void`.

This form has more code than `!void`. It is useful when you want to select the message and the exit status yourself. For all other programs, `!void` with `try` is shorter, and you lose no information.

## Buffers, and the `flush` call

`writeStreamingAll` is sufficient for one fixed string. But real programs format their output. For formatted output, use a buffered writer:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("{s} v{d}.{d}\n", .{ "zig", 0, 16 });
    for (0..3) |i| try out.print("  line {d}\n", .{i});

    // The writer writes nothing until `flush` empties the buffer.
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.buffered-stdout`)*

From Zig 0.15, writers have a buffer, and the buffer is part of the **interface**, not of the implementation. People call this change *"writergate"*. You supply the memory, thus there is no hidden allocation.

There is a cost: **Zig writes nothing until you call `flush`**. If you remove the `try out.flush()` line, the program gives no output. The program formats the greeting and copies it into `buf`. When the program exits, the data in `buf` is lost. If a program must print text but prints nothing, first make sure that the program calls `flush`.

The **Edit** button opens the snippet, and the **Copy** button copies the source. To run an edited version, you need a Zig compiler in the browser. This site does not have one yet. Thus the toolbar tells you this and offers to send your version to an external playground. Each unedited snippet runs on this site.
