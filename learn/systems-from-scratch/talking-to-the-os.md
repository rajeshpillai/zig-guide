# Talking to the Operating System

> Your program is handed streams it did not open, and owes a status back.

Every chapter so far has been about the inside of your program: its bytes, its
memory, its failures. This one is about the edge, because a program cannot
actually do anything from in there. It cannot read a file, write to your
terminal, or open a connection. It can only compute.

Anything that reaches the outside is done by asking the operating system. That
request is a **system call**. Your program stops. The kernel does the thing,
using privileges your program does not have. Control comes back with a result.

That is the boundary, and everything you think of as I/O crosses it.

The shape of the arrangement is the part to keep, because it is older than
almost everything else you use and it has not changed:

- The operating system hands your program some things when it starts, without
  being asked.
- Your program asks for anything else by number: it refers to what it opened
  with a small integer, not a name.
- When it ends, it hands back one number, and that number is the only thing the
  parent process is guaranteed to learn.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // Three streams were already open when main was entered. Nothing in this
    // program opened them, and the numbers are not arbitrary: every process
    // starts with the same three.
    try out.print("stdin  is descriptor {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout is descriptor {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr is descriptor {d}\n\n", .{std.Io.File.stderr().handle});

    // They go to different places, which is the whole reason there are two
    // output streams rather than one. This line is the program's result.
    try out.writeAll("this line went to stdout: the program's output\n");
    try out.flush();

    // And this one is for the person watching. Redirect the program into a
    // file and this still appears on the terminal.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr: not part of the output\n");
    try err_writer.interface.flush();

    // Returning normally from main is a status of 0, which by convention
    // means success. Returning an error would make it non-zero, and that is
    // the only thing the parent process is guaranteed to learn.
    try out.writeAll("\nreturning from main reports success to whoever ran us\n");
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.talking-to-the-os`)*

## What just happened

**Three streams were already open.** The program did not open them and cannot
choose their numbers. Descriptor 0 is standard input, 1 is standard output,
and 2 is standard error. That is true of every process on every Unix-derived
system. It is why a shell can connect two programs together without either of
them agreeing to it in advance.

**A descriptor is an integer and nothing else.** It is not a handle object with
methods hiding inside it. It is a number the kernel uses to look up what you
opened, in a table it keeps for your process. Opening a file gives you the
next free number. This is where "everything is a file" stops being a slogan. A
file, a socket, a pipe and a terminal are all just numbers into that table,
and `read` works on all of them.

**Two output streams, on purpose.** stdout is the program's *result*, the bytes
another program would consume if you piped this one into it. stderr is for the
person watching. The distinction only becomes visible when you redirect: run
this locally as `zig run talking-to-the-os.zig > out.txt` and the stdout lines
land in the file while the stderr line still appears on your terminal. Getting
this wrong is why some tools are painful to script.

**Returning from `main` reported 0.** A process ends with a status, and by
convention 0 means success and anything else means a specific kind of failure.
One small integer is not much to say with. That is exactly why programs also
write to stderr. The status says *that* it failed. stderr says *what*
happened.

## Check yourself

This program ran in your browser, where there is no operating system, no
process table and no kernel to call. So why did the descriptors print 0, 1 and
2?

Because the page runs it under **WASI**. That is an interface with the same
shape as the real thing: the same numbering, the same calls, written in
JavaScript against the browser instead of against a kernel.

The program cannot tell the difference. That is the point of an interface, and
it is why most of the snippets in this guide can run on a page at all. The
five chapters in [the OS section](https://www.ziglang.in/learn/os/) that genuinely need a kernel say
so and do not offer a Run button.

## If you have written C

You have already met all of this, under the names `open`, `read`, `write`,
`close`, and `exit`. Zig's `std.Io.File` is a descriptor and a couple of flag
bits, and you can build one out of the number 1 by hand and write to standard
output with it. The [file descriptors](https://www.ziglang.in/learn/os/file-descriptors/) chapter
does exactly that.

Two differences show up immediately. A failed call returns an error rather
than setting a global `errno`, so it composes with `try` like everything else.
And the ability to do I/O arrives as an argument: `main` receives an `init`,
and `init.io` is what the writers above were built from. There is no global
`stdout` to reach for, which means a function that does not take an `Io`
cannot quietly touch the outside world.

## Where to go next

That is the track. You now have the model the rest of the guide assumes. Bytes
and types. Sizes and what they cost. Addresses and the stack. Ownership.
Bounds and build modes. Text as bytes. Structs as layout. Errors as values.
And the boundary with the operating system.

If you arrived here before the rest of the guide, [Getting
Started](https://www.ziglang.in/learn/getting-started/) installs a compiler and gets these programs
running on your own machine. [Language Basics](https://www.ziglang.in/learn/language-basics/) then
covers the same ground from the language side: what `*T` means precisely, how
optionals remove null, what `comptime` is.

If you came the other way, having already read those, go to [the operating
system](https://www.ziglang.in/learn/os/) next. It takes the descriptors above and uses them to open
files, start processes, and connect pipes. And if you would rather learn by
building, [Data Structures](https://www.ziglang.in/learn/data-structures/) starts with a linked
list, the smallest program that makes you answer the ownership question from
[chapter five](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/) for real.
