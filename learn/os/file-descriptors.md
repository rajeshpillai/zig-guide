# A File Descriptor Is a Number

> Each thing that the operating system gives you to read or write is an integer.

Open a file, accept a connection, or create a pipe. Each of these operations
gives you a small non-negative integer, and you hold only that integer. Your
side has no object.

The kernel keeps one table for each process, and the number is an index into
that table. Each later call identifies the thing that you opened, because you
give the number back to the call.

Press Run.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // A `std.Io.File` is a handle and one flag bit. The handle is the number.
    // Its type is the descriptor type of the platform.
    try out.print("File.Handle = {s}\n", .{@typeName(std.Io.File.Handle)});
    try out.print("a File is {d} bytes\n\n", .{@sizeOf(std.Io.File)});

    // Each process starts with these three. No code opened them. They were
    // already open when main started.
    try out.print("stdin  {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr {d}\n\n", .{std.Io.File.stderr().handle});
    try out.flush();

    // The File that `stdout()` returns is not special. Build a File from the
    // number 1, and the File writes to the same stream.
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

This is the full declaration of `std.Io.File` in the standard library,
without its methods. A `File` is a descriptor and one bit. The bit tells if
the file was opened non-blocking.

On all POSIX targets and on WASI, `fd_t` is `i32`. On Windows, `fd_t` is a
`HANDLE`. For this reason, the declaration uses the name of the type and does
not write out the type.

The struct holds nothing more. Thus you can build a `File` from a raw number,
and the operation needs no cast:

```zig
const by_hand: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
```

That value and `std.Io.File.stdout()` are the same eight bytes. When you write
through either value, the bytes go to the same place.

## The three that you get

A process starts with descriptors 0, 1 and 2 already open. No code in your
program opened them. The shell, or the parent process, prepared them before
your first instruction ran:

| Number | Name | Convention |
| --- | --- | --- |
| 0 | standard input | where the program reads from |
| 1 | standard output | where its results go |
| 2 | standard error | where its diagnostics go |

The numbers are a convention. But the kernel and all programs agree on the
convention, so in practice the convention is as strict as a rule. `zig build`,
the `2>&1` of your shell, and the redirect that a CI system applies to your
test run all use this convention.

Nothing else about the numbers is certain. The next descriptor that you open
gets the lowest free number. In a new process, that number is 3. After any
open or close, the number can be different. Code that hardcodes 4 works until
a library opens a log file before your function runs.

## The sandbox keeps the numbers

This chapter runs in your browser. The browser has no kernel, no descriptor
table and no processes. But the numbers are still 0, 1 and 2, because WASI
copied the interface.

The host gives descriptors to a module. The module identifies the descriptors
by number. It reads and writes through calls that take that number as their
first argument.

The descriptor number is not a detail of the Linux implementation that went
into the API by accident. The number is the API. The API is so thin that a
wasm runtime in a browser tab can implement it. A program for
a kernel cannot see the difference.

## Where descriptors come from next

The rest of this section uses descriptors in four ways:

- It writes to the descriptors that you got at startup.
- It gives changed copies to a child process.
- It holds one end of a pipe.
- It closes a descriptor to show that the program has no more data.

Sockets in [Network Programming](https://www.ziglang.in/learn/networking/what-is-a-socket/) are
the same integers again, with a different call that creates them.
