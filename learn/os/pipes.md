# Pipes Are the Child's Streams

> A pipe is a descriptor at each end and an end-of-file in the middle.

A pipe is a one-way buffer in the kernel, with a descriptor at each end. Write
into one end, and read from the other end. A pipe carries only bytes. It has
no message boundaries and no types. You cannot ask how much data will come.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // The child half: read standard input to end of file. Write it back in upper case.
    if (args.next() != null) {
        var in_buf: [256]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
        var out_buf: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io, &out_buf);

        while (try reader.interface.takeDelimiter('\n')) |line| {
            var upper: [64]u8 = undefined;
            const shouted = std.ascii.upperString(upper[0..line.len], line);
            try writer.interface.print("{s}\n", .{shouted});
        }
        try writer.interface.flush();
        std.process.exit(0);
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // `.pipe` on a stream means: do not give the stream of the parent to the
    // child. Make a new pipe, and give the other end to the parent as a `File`.
    var child = try std.process.spawn(io, .{
        .argv = &.{ path_buf[0..len], "child" },
        .stdin = .pipe,
        .stdout = .pipe,
    });

    // Both ends are ordinary descriptors, after the three that the process
    // started with. The numbers depend on the other files that this process
    // has open. Thus the test checks that the numbers are new. It does not
    // check that they are 4.
    const fresh = child.stdin.?.handle > 2 and child.stdout.?.handle > 2;
    try out.print("both ends are fresh descriptors: {}\n\n", .{fresh});
    try out.flush();

    var to_child_buf: [256]u8 = undefined;
    var to_child = child.stdin.?.writerStreaming(io, &to_child_buf);
    try to_child.interface.writeAll("one\ntwo\nthree\n");
    try to_child.interface.flush();

    // The close tells the child that the input is complete. The child is
    // blocked in a read. The read ends only when no write end of that pipe
    // exists. If the parent keeps this descriptor open and then waits for
    // output, the parent waits forever.
    child.stdin.?.close(io);
    child.stdin = null;

    var from_child_buf: [256]u8 = undefined;
    var from_child = child.stdout.?.readerStreaming(io, &from_child_buf);
    const reply = try from_child.interface.allocRemaining(gpa, .limited(4096));
    defer gpa.free(reply);

    try out.print("{s}", .{reply});
    try out.print("\nterm: {f}\n", .{try child.wait(io)});
    try out.flush();
}
```

*CI builds and runs this snippet natively. The snippet makes the pipe when it spawns a process, and a WASI sandbox cannot spawn a process. (`14-os.pipes`)*

## There is no `std.posix.pipe`

The standard library does not have a `std.posix.pipe` function. `pipe2`
exists inside the `Io` implementations, `std.Io.Threaded` and `std.Io.Uring`.
There, `pipe2` is a detail of how the implementations schedule work.

The standard library gives you the useful case. Ask for a pipe on a stream of
a child, and you get the other end back as an `Io.File`.

```zig
var child = try std.process.spawn(io, .{
    .argv = &.{ self, "child" },
    .stdin = .pipe,
    .stdout = .pipe,
});
```

The `|` of the shell does the same thing. `.pipe` on a stream has this
meaning: do not give my stream to the child, make a new pipe, and give me the
other end. Then `child.stdin` and `child.stdout` are ordinary files. All
that you know about readers and writers applies to them without change.

The descriptors are new numbers after the three that the process started with.
Nothing makes the numbers certain. Thus the snippet checks that the numbers
are more than 2. It does not check that they are 4 and 5.

The numbers can be different with a different `Io` implementation. A test
that asserts exact numbers fails on a computer that opened one more file at
startup.

## Close the pipe to send the message

```zig
try to_child.interface.flush();
child.stdin.?.close(io);
child.stdin = null;
```

The child reads until end of file. On a pipe, end of file means that all of
the write ends are closed, and the parent holds one write end. Assume that a
parent writes, does not close the pipe, and then waits for output. That parent
waits forever.

In that case, the child is blocked in a read that cannot return. The parent
is blocked in a read from a child that will never write. Neither process
failed, and neither process can continue.

This is the classic pipe deadlock. The deadlock has a second form. A pipe
holds a fixed quantity of data, by default 64 KB on Linux. Assume that a
parent writes more than that before it reads anything. The parent fills the
buffer and is blocked in its own write. At the same time, the child fills its
output pipe and is blocked in its own write.

`std.process.run` prevents both forms, because it drains the pipes and waits
in the correct order. Thus use `std.process.run` when the output fits in
memory.

After the close, you must set `child.stdin = null`. `Child.wait` closes the
streams that it still holds. If a program closes a descriptor two times, a
bug occurs much later. The bug occurs after the kernel gives the number to a
different file that you use.

## `SIGPIPE`, the other direction

Assume that you write to a pipe, and the read end no longer exists. Then the
kernel sends `SIGPIPE`. The default action of `SIGPIPE` is to kill your
process.

That default is the reason that `head` works. In `producer | head -3`, the
producer stops when `head` stops its reads. No person writes code to make
this occur.

For the same reason, a server that runs for a long time ignores the signal.
Instead, the server handles the `error.BrokenPipe` from the write. If a client
disconnects in the middle of a reply, only that connection must end. The
process that serves all the other connections must continue.
[Signals](https://www.ziglang.in/learn/os/signals/) is the next chapter.
