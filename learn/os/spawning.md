# Spawn a Process

> A child is a program, an argument list, and a status code that the parent receives.

To run another program, you make three decisions:

- What to run.
- What the program inherits.
- What to do with the number that the program leaves when it ends.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // With an argument, this program is the child. The program runs itself.
    // Thus it does not need a system binary to be installed.
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "ok")) {
            var buf: [64]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            try w.interface.writeAll("hello from the child\n");
            try w.interface.flush();
            std.process.exit(0);
        }
        // A program reports failure with a number, and only a number. If there
        // is a reason, the program writes the reason to stderr.
        std.process.exit(3);
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);
    const self = path_buf[0..len];

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // `run` spawns, collects both streams to the end, and waits. Use it when
    // the output is small and you want all of the output.
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

    // A status is a `u8`. Thus there are only 256 values, and only 0 means
    // success. The program decides the meaning of the other values.
    switch (failed.term) {
        .exited => |code| try out.print("exit code:     {d}\n", .{code}),
        else => try out.print("killed or stopped rather than exited\n", .{}),
    }

    try out.flush();
}
```

*CI builds and runs this snippet natively. A WASI sandbox cannot create a process, and a browser tab has nothing to create a process from. (`14-os.spawning`)*

## The snippet runs itself

```zig
const len = try std.process.executablePath(io, &path_buf);
const ok = try std.process.run(gpa, io, .{ .argv = &.{ path_buf[0..len], "ok" } });
```

The snippet does not use `/bin/echo`, and this is intentional. A chapter that
runs a system binary fails on each computer that keeps that binary in a
different place. This site claims that CI ran each snippet today.

`executablePath` gives the program that runs its own path. A first argument
tells the copy which part of the program to run.

Real programs also do this. A supervisor can start itself again with a flag to
spawn workers. Thus the supervisor is sure that the workers have the same
version as the supervisor.

## `run` against `spawn`

`std.process.run` does four things in one call:

1. It spawns the child.
2. It reads standard output and standard error to end of file.
3. It waits for the child.
4. It gives you the two buffers.

Use `run` when the output is small and you want all of the output. Do not use
`run` when the output is large, or when you must react to the output when it
arrives.

`.stdout_limit` sets the maximum quantity of output that `run` collects. If
the output is more than that limit, `run` returns `error.StreamTooLong`. Thus
`run` does not fill memory while a child continues to write.

`std.process.spawn` returns immediately when the child exists. After that, you
control everything: the streams that you asked for, when to read them, and
when to wait. [Pipes](https://www.ziglang.in/learn/os/pipes/) uses that call.

Both functions go through `Io`. The creation of a process is an operation on
the interface. It is not a free function that calls the kernel without your
knowledge. Thus, with a different `Io` implementation, a program spawns in the
way that the implementation spawns.

## The status code

```zig
switch (failed.term) {
    .exited => |code| ...,
    .signal => |sig| ...,
    .stopped, .unknown => ...,
}
```

`Term` is a union, because the question "how did the process end?" has more
than one answer. A process that exited selected its own status. A process that
was killed selected nothing. The shell reports the signal number as an exit
code with the `128 + n` convention, and this loses that difference.

A program can select from 256 codes, and only 0 means success. These three
ask the same question and get the same one-bit answer:

- `&&` in a shell.
- A step that fails in CI.
- `Term.success()`.

Put all other information for the caller on standard error, because a code has
no space for it.

The child in the snippet exits with 3, and the snippet itself exits with 0.
This is intentional. Each snippet on this site must exit with 0 to pass the
gate. Thus this page can show you a nonzero code only from a child that fails
under a parent that succeeds.

## What a child inherits

By default, a child inherits three things:

- The environment.
- The working directory.
- Descriptors 0, 1 and 2.

The descriptors are the reason that the output of a child appears in your
terminal, and no code makes this occur. The child got the same descriptor 1
that you got.

You can override each one at the spawn call:

- `environ_map` replaces the environment.
- `cwd` changes the directory.
- `stdin`, `stdout` and `stderr` each take `inherit`, `ignore`, `close`, an
  open `file`, or a `pipe`.

When you replace the environment, the search for the program does not change.
The search still uses the `PATH` of the parent. If you set a different `PATH`
in the environment of the child, the search for the child does not change.
