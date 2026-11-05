# Exit the Process

> exit stops the process. It does not return from your program.

The snippet writes two lines and registers two `defer` statements. Only one
line comes out.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The program registers these now. The exit below skips each of them.
    defer std.debug.print("this defer never runs\n", .{});
    defer out.flush() catch {};

    try out.writeAll("first line, flushed by hand\n");
    try out.flush();

    try out.writeAll("second line, still sitting in the buffer\n");

    // The process stops here. This is not a return. No defer runs, and the
    // program flushes no buffer. Thus the program loses the second line above, and
    // it loses the memory that held the line.
    std.process.exit(0);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`14-os.exiting`)*

## What `exit` skips

```zig
defer std.debug.print("this defer never runs\n", .{});
defer out.flush() catch {};

try out.writeAll("second line, still sitting in the buffer\n");
std.process.exit(0);
```

`std.process.exit` is `noreturn`. It never returns to the caller, so no code
between the call and the end of `main` runs. No `defer` runs at any depth of
the stack, no `errdefer` runs, and the program flushes nothing.

Look at the lost line. Those bytes were in a buffer in the memory of your
process. The operating system never received the bytes, and then the process
ended. Output often disappears in this way from a program that "definitely
printed it".

The second `defer` above is the one that flushes. It looks like it protects
the output. But it never runs, so it protects nothing.

When `main` returns normally, every `defer` runs. Thus an error return from
`main` and `exit(1)` are not the same:

- An error return unwinds the stack and runs the cleanup.
- `exit(1)` stops the process immediately.

## The status that you leave

`exit` takes a `u8`. Zero means success, and you decide the meaning of each
other value. This is the same one-bit protocol that the parent sees as `Term`
in [Spawn a Process](https://www.ziglang.in/learn/os/spawning/).

When `main` returns an error, Zig sets a nonzero status for you. In debug
builds, Zig also prints the error name with a stack trace. For a tool, that
is the correct default.

Select a specific code only for a program whose callers make a decision on
the code. `grep` returns 1 for "no match" and 2 for "something went wrong". A
shell script can act on that difference, but it cannot act on an error
message.

## `cleanExit`, and why it does nothing in Debug

```zig
pub fn cleanExit(io: Io) void {
    if (builtin.mode == .debug) return;
    _ = io.lockStderr(&.{}, .no_color) catch {};
    exit(0);
}
```

A program that is about to exit does not have to free anything. The kernel
takes back the full address space. A walk through a tree of allocations to
release memory that will disappear soon only makes the program slower to
stop.

`std.process.cleanExit` is that shortcut, with the one condition that makes
the shortcut safe:

- In Debug, the function returns and lets your teardown code run. Thus the
  leak detector still sees a program that freed everything, and it can still
  tell you about the leak that is important.
- In release builds, the function exits immediately.

The Zig compiler itself calls `cleanExit`.

Because the behavior changes with the build mode, this page describes the call
and does not run it. Assume that the output of a snippet changes between
`-Doptimize=Debug` and `ReleaseSmall`, which this site ships. Then the snippet
passes CI, but readers who use the other build mode see the wrong output.

## `abort` is not an exit

`std.process.abort` ends the process abnormally. It raises `SIGABRT`, which
runs a handler if you installed one. Then it makes sure that the process
stops in all cases. It sets no status code and runs no cleanup. Usually, it
leaves a core dump.

Use `abort` for a broken invariant, where more work can cause damage and
there is nothing useful to report. Do not use `abort` for a file that does not
exist. Use `exit` when the program has no more work. Use `abort` when the
program gets to a state that must be impossible.
