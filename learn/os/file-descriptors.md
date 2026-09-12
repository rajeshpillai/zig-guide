# A File Descriptor Is a Number

> Everything the operating system hands you to read or write is an integer.

Open a file, accept a connection, create a pipe. Each one gives you back a
small non-negative integer, and that integer is the whole of what you hold.
There is no object on your side. The kernel keeps a table per process, the
number is an index into it, and every later call names the thing you opened by
passing the number back.

Press Run.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // A `std.Io.File` is a handle and two flag bits. The handle is the number,
    // and its type is whatever the platform calls a descriptor.
    try out.print("File.Handle = {s}\n", .{@typeName(std.Io.File.Handle)});
    try out.print("a File is {d} bytes\n\n", .{@sizeOf(std.Io.File)});

    // The three every process starts with. Nothing opened them; they were
    // already there when main was entered.
    try out.print("stdin  {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr {d}\n\n", .{std.Io.File.stderr().handle});
    try out.flush();

    // Nothing is special about the File that `stdout()` returns. Build one out
    // of the number 1 and it addresses the same stream.
    const by_hand: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
    var hand_buf: [64]u8 = undefined;
    var hand_writer = by_hand.writerStreaming(io, &hand_buf);
    try hand_writer.interface.writeAll("written through a hand-built File\n");
    try hand_writer.interface.flush();

    try out.print("same handle: {}\n", .{by_hand.handle == std.Io.File.stdout().handle});
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`14-os.file-descriptors`)*

## What a `File` is

```zig
handle: Handle,
flags: Flags,

pub const Handle = std.posix.fd_t;
```

That is the entire declaration of `std.Io.File` in the standard library, minus
its methods. A descriptor and one bit saying whether it was opened
non-blocking. `fd_t` is `i32` on every POSIX target and on WASI; on Windows it
is a `HANDLE`, which is why the type is named rather than written out.

Because the struct holds nothing else, building one out of a raw number is not
a trick and needs no cast:

```zig
const by_hand: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
```

That value and `std.Io.File.stdout()` are the same eight bytes, and writing
through either sends bytes to the same place.

## The three you are given

A process starts with descriptors 0, 1 and 2 already open, and nothing in your
program opened them. The shell, or the parent process, arranged them before
your first instruction ran:

| Number | Name | Convention |
| --- | --- | --- |
| 0 | standard input | where the program reads from |
| 1 | standard output | where its results go |
| 2 | standard error | where its diagnostics go |

The numbering is convention with one exception: it is convention that the
kernel and every program agree on, so it is as binding as a rule. `zig build`,
your shell's `2>&1`, and the redirect a CI system applies to your test run all
assume it.

Nothing else about the numbers is promised. The next descriptor you open takes
the lowest free number, which is 3 in a fresh process and something else the
moment anything has been opened or closed. Code that hardcodes 4 works until
the day a library opens a log file before your function runs.

## The sandbox keeps the numbering

This chapter runs in your browser, which has no kernel, no descriptor table
and no processes. The numbers still come out 0, 1 and 2, because WASI copied
the interface. A module is handed descriptors by its host, refers to them by
number, and reads and writes through calls that take that number as their
first argument.

Which is the useful thing to notice about descriptors. The number is not an
implementation detail of Linux that leaked into the API. It is the API, thin
enough that a wasm runtime in a browser tab can implement it and a program
written against a kernel cannot tell.

## Where they come from next

The rest of this section is descriptors doing the four things worth doing to
them. Writing to the ones you were given. Passing modified copies to a child.
Holding one end of a pipe. And closing one to say you are finished. Sockets in
[Network Programming](https://www.ziglang.in/learn/networking/what-is-a-socket/) are the same
integers again, with a different call to create them.
