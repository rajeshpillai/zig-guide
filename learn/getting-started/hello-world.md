# Hello World

> Your first Zig program, and why main now takes an argument.

Here is the shortest Zig program that prints something. It is also close to
what every older Zig tutorial opens with, and it still compiles on current
master:

```zig
const std = @import("std");

// Two separate old habits in four lines: the parameterless `main`, and printing
// through `std.debug.print`. Both still work on current master, and they are
// independent of each other.
pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
```

*Compiled by CI against master every night, but not executed here. Save it as hello.zig to follow along. (`01-getting-started.older-main`)*

Two independent things are worth pulling apart in those four lines: the call
that prints, and the signature of `main`. Changing one does not force the
other.

A Run button on this site means the browser sandbox can execute that snippet.
It says nothing about which shape to prefer.

## When to reach for `std.debug.print`

`std.debug.print` needs no setup and returns `void`, so there is nothing to
thread through and nothing to handle. It is for lines you intend to delete:
checking that a loop runs, dumping a struct while you build a feature. Reach
for it freely while working.

It is not for a program's output, and the reason shows up the first time you
use a shell. stdout carries what another program would read if you piped this
one; stderr carries what the person running it reads. The greeting above goes
to **stderr**, so redirecting the program into a file leaves the file empty.
Check it: `zig run hello.zig > out.txt` prints the greeting to your terminal
and writes zero bytes to `out.txt`. The [standard
streams](https://www.ziglang.in/learn/os/standard-streams/) chapter puts both side by side.

There is a second reason. `std.debug.print` ends in `catch return`: if the
write fails, the output is gone and the program never finds out. That is the
right trade for a temporary line and the wrong one for anything you ship.

So: `std.debug.print` while you are working, and a writer you were handed for
what the program is actually for. The rest of this page is the second kind.

## Why does `main` take a parameter?

The program above uses `pub fn main() !void`. On current Zig master there is
also a form that takes an argument:

```zig
pub fn main(init: std.process.Init) !void
```

`init.io` is an **`Io`**: a value carrying the ability to do input and output.
Writing to a file, opening a socket, reading the clock: each of those takes an
`Io` as an argument. So code cannot block or start a thread unless a caller
handed it one. There is no global `stdout` to reach for. You are handed the
capability to write.

Here is the same greeting on stdout, through the `Io` that `main` received.
Press **Run**; it executes in your browser as WebAssembly.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.hello-world`)*

Who hands `main` its `Io` is the caller's choice, which is where the threaded
and event-loop implementations come in. That is [the `Io`
interface](https://www.ziglang.in/learn/standard-library/io-interface/), a later chapter.

If you have met Zig's `Allocator`, this is the same move applied to I/O: the
caller supplies the mechanism, and nothing happens behind your back. If you
have not, do not worry about it here.
[Allocators](https://www.ziglang.in/learn/standard-library/allocators/) come later, and nothing on
this page depends on them.

## Buffering, and the `flush` you must not forget

`writeStreamingAll` is fine for a single fixed string, but real programs
format output. For that you want a buffered writer:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("{s} v{d}.{d}\n", .{ "zig", 0, 16 });
    for (0..3) |i| try out.print("  line {d}\n", .{i});

    // Nothing is written until the buffer is drained.
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`01-getting-started.buffered-stdout`)*

Since Zig 0.15 (the release nicknamed *"writergate"*), writers are buffered
and the buffer is part of the **interface**, not the implementation. You
supply the memory, which means no hidden allocation.

The tradeoff is that **nothing is written until you `flush`**. Remove the `try
out.flush()` line and the program produces no output at all: the greeting is
formatted, copied into `buf`, and then thrown away when the program exits. It
is the first thing to check when a program that clearly should print something
prints nothing.

The **Edit** button opens the snippet, and **Copy** takes the source. Running
an edited version needs a Zig compiler in the browser. This site does not
carry one yet, so the toolbar says so and offers to send your version to an
external playground. Every unedited snippet runs here.
