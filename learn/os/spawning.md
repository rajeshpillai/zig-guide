# Spawning a Process

> A child is a program, an argument list, and a status code coming back.

Running another program is three decisions: what to run, what it inherits, and
what you do with the number it leaves behind.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // Spawned with an argument, this program is the child. Rather than depend
    // on a system binary being installed, it runs itself.
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "ok")) {
            var buf: [64]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            try w.interface.writeAll("hello from the child\n");
            try w.interface.flush();
            std.process.exit(0);
        }
        // A program reports failure with a number, and only a number. The
        // reason, if there is one, goes to stderr.
        std.process.exit(3);
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);
    const self = path_buf[0..len];

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // `run` spawns, collects both streams to completion, and waits. It is the
    // right call when the output is small and you want all of it.
    const ok = try std.process.run(gpa, io, .{ .argv = &.{ self, "ok" } });
    defer gpa.free(ok.stdout);
    defer gpa.free(ok.stderr);
    try out.print("child stdout: {s}", .{ok.stdout});
    try out.print("child term:   {f}\n\n", .{ok.term});

    const failed = try std.process.run(gpa, io, .{ .argv = &.{ self, "fail" } });
    defer gpa.free(failed.stdout);
    defer gpa.free(failed.stderr);
    try out.print("failing child: {f}\n", .{failed.term});
    try out.print("succeeded:     {}\n", .{failed.term.success()});

    // A status is a `u8`, so there are only 256 of them and 0 is the only one
    // that means success. Everything else is yours to define.
    switch (failed.term) {
        .exited => |code| try out.print("exit code:     {d}\n", .{code}),
        else => try out.print("killed or stopped rather than exited\n", .{}),
    }

    try out.flush();
}
```

*Built and run natively by CI. Creating a process is the one thing a WASI sandbox cannot do, and a browser tab has nothing to create it from. (`14-os.spawning`)*

## The snippet runs itself

```zig
const len = try std.process.executablePath(io, &path_buf);
const ok = try std.process.run(gpa, io, .{ .argv = &.{ path_buf[0..len], "ok" } });
```

There is no `/bin/echo` in the snippet, on purpose. A chapter that shells out
to a system binary is a chapter that fails on the machine where that binary
lives somewhere else. This site's whole claim is that CI ran every snippet
today. `executablePath` gives the running program its own path, and a first
argument tells the copy which half of the program to be.

It is also a real technique. A parent that re-executes itself with a flag is
how a supervisor spawns workers it can be sure match its own version.

## `run` against `spawn`

`std.process.run` does four things in one call: spawn, read standard output
and standard error to end of file, wait, and hand you both buffers. It is the
right call when the output is small and you want all of it. It is the wrong
one when the output is large, or when the point is to react to it as it
arrives. `.stdout_limit` caps how much it will collect, and it returns
`error.StreamTooLong` rather than filling memory with a child that will not
stop talking.

`std.process.spawn` returns as soon as the child exists, and everything after
that is yours: the streams you asked for, when to read them, and when to wait.
[Pipes](https://www.ziglang.in/learn/os/pipes/) is that call.

Both go through `Io`. Creating a process is an operation on the interface, not
a free function reaching for the kernel behind your back. So a program written
against a different `Io` implementation spawns the way that implementation
spawns.

## The status code

```zig
switch (failed.term) {
    .exited => |code| ...,
    .signal => |sig| ...,
    .stopped, .unknown => ...,
}
```

`Term` is a union because "how did it finish" has more than one answer. A
process that exited chose its own status. A process that was killed did not
choose anything, and reporting the signal number as an exit code (the shell's
`128 + n` convention) loses that distinction.

Of the 256 codes a program can choose, only 0 means success. That asymmetry is
the whole protocol: `&&` in a shell, a failing step in CI, and
`Term.success()` all ask the same question and all get the same one-bit
answer. Everything else you want the caller to know goes on standard error,
because a code has no room for it.

The snippet's child exits 3 and the snippet itself exits 0, which is not an
accident of style. Every snippet on this site is gated on exiting 0. A failing
child observed by a succeeding parent is the only way this page can show you a
nonzero code at all.

## What a child inherits

By default: the environment, the working directory, and descriptors 0, 1 and
2. That last one is why a child's output appears in your terminal without
anyone arranging it. The child was handed the same descriptor 1 you were.

Each is overridable at the spawn call. `environ_map` replaces the environment,
`cwd` changes the directory, and `stdin`, `stdout` and `stderr` each take an
`inherit`, `ignore`, `close`, an open `file`, or a `pipe`. Replacing the
environment does not replace how the program is found. That still uses the
parent's `PATH`, so a child cannot be sent looking for itself down a path you
invented for it.
