# Pipes Are the Child's Streams

> A pipe is a descriptor at each end and an end-of-file in the middle.

A pipe is a one-way buffer in the kernel with a descriptor at each end. Write
into one end, and read out of the other. It carries only bytes. It has no
message boundaries and no types, and you cannot ask how much data is coming.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // The child half: read standard input to end of file, write it back in upper case.
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

    // `.pipe` on a stream means: do not pass the parent's stream to the child.
    // Make a new pipe and give the parent the other end as a `File`.
    var child = try std.process.spawn(io, .{
        .argv = &.{ path_buf[0..len], "child" },
        .stdin = .pipe,
        .stdout = .pipe,
    });

    // Both ends are ordinary descriptors, allocated past the three the
    // process started with. Which numbers they got depends on what else this
    // process has open, so the test checks that they are new, not that they
    // are 4.
    const fresh = child.stdin.?.handle > 2 and child.stdout.?.handle > 2;
    try out.print("both ends are fresh descriptors: {}\n\n", .{fresh});
    try out.flush();

    var to_child_buf: [256]u8 = undefined;
    var to_child = child.stdin.?.writerStreaming(io, &to_child_buf);
    try to_child.interface.writeAll("one\ntwo\nthree\n");
    try to_child.interface.flush();

    // Closing the pipe tells the child the input is over. The child is blocked
    // in a read that only ends when every write end of that pipe is gone. A
    // parent that keeps this descriptor open and then waits for output waits
    // forever.
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

*Built and run natively by CI. The pipe is created by spawning a process, which a WASI sandbox cannot do. (`14-os.pipes`)*

## There is no `std.posix.pipe`

The standard library does not have one. `pipe2` exists inside the `Io`
implementations, `std.Io.Threaded` and `std.Io.Uring`, where it is an
implementation detail of how they schedule work. The standard library
offers you the useful case: ask for a pipe on a child's stream, and get the
other end back as an `Io.File`.

```zig
var child = try std.process.spawn(io, .{
    .argv = &.{ self, "child" },
    .stdin = .pipe,
    .stdout = .pipe,
});
```

This is what the shell's `|` does. `.pipe` on a stream means: do not give the
child my stream, make a new pipe, and give me the other end. `child.stdin` and
`child.stdout` are then ordinary files, and everything you know about readers
and writers applies to them unchanged.

The descriptors are new numbers past the three the process started with.
Nothing promises which numbers, so the snippet checks that they are greater
than 2 rather than that they are 4 and 5. They would be different under a
different `Io` implementation. A test that asserts exact numbers fails on a
machine that opened one more file at startup.

## Closing is the message

```zig
try to_child.interface.flush();
child.stdin.?.close(io);
child.stdin = null;
```

The child is reading until end of file. End of file on a pipe means every
write end has been closed, and the parent is holding one. A parent that
writes, does not close, and then waits for output waits forever. The child is
blocked in a read that cannot return, and the parent is blocked in a read of a
child that will never write. Neither process has failed, and neither can
continue.

This is the classic pipe deadlock. It has a second form.
Pipes hold a fixed amount, 64 KB on Linux by default. A parent that writes
more than that before reading anything fills the buffer and blocks in its own
write, while the child fills its output pipe and blocks in its.
`std.process.run` avoids both by draining and waiting in the right order,
so use it whenever the output fits in memory.

Setting `child.stdin = null` after closing is required. `Child.wait`
closes the streams it still holds. Closing a descriptor twice causes a bug that
shows up much later, when the number has been given to another file you are
using.

## `SIGPIPE`, the other direction

Write to a pipe whose read end is gone and the kernel sends `SIGPIPE`, whose
default action is to kill your process. That default is what makes `head` work:
`producer | head -3` ends the producer once `head` stops reading, without
anyone writing code to arrange it.

For the same reason, a long-running server ignores the signal and handles the
`error.BrokenPipe` from the write instead. A client that disconnects mid-reply
should end one connection, not the process serving all the others.
[Signals](https://www.ziglang.in/learn/os/signals/) is the next chapter.
