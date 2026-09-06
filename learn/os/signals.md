# Signals

> A handler interrupts you between two instructions. Set a flag and return.

A signal is the operating system calling a function in your program at a
moment you did not choose. It is not a queue you poll, and not a message you
receive. Your thread is stopped between two instructions, the handler runs on
that thread's stack, and then the instruction that was next runs as though
nothing happened.

```zig
const std = @import("std");
const posix = std.posix;

/// The only thing a handler here does. `std.atomic.Value` because the handler
/// runs between two arbitrary instructions of the code below, and a plain
/// `bool` written there is a data race with whatever that code was doing.
var caught: std.atomic.Value(u32) = .init(0);

fn onUsr1(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    caught.store(1, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // `sigaction` returns nothing. It used to return an error union, and the
    // handler used to take a `c_int`; both changed, so a handler copied from
    // an older tutorial does not compile rather than misbehaving.
    var action: posix.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.USR1, &action, null);

    try out.print("caught before: {d}\n", .{caught.load(.seq_cst)});
    try posix.raise(.USR1);
    try out.print("caught after:  {d}\n\n", .{caught.load(.seq_cst)});

    // Blocking does not discard a signal, it defers it. USR1 raised while
    // blocked stays pending, and is delivered the moment it is unblocked.
    caught.store(0, .seq_cst);
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .USR1);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    try posix.raise(.USR1);
    try out.print("while blocked: {d}\n", .{caught.load(.seq_cst)});
    try out.flush();

    posix.sigprocmask(posix.SIG.UNBLOCK, &mask, null);
    try out.print("once unblocked: {d}\n\n", .{caught.load(.seq_cst)});

    // Handing the signal back to the kernel's default disposition. For USR1
    // that default is "terminate the process", which is why an unhandled one
    // kills a program that never asked for it.
    var default: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.USR1, &default, null);
    try out.writeAll("USR1 restored to its default disposition\n");

    try out.flush();
}
```

*Built and run natively by CI. There are no signals in a WASI sandbox, because there is no kernel to deliver them. (`14-os.signals`)*

## Two things changed, and both are compile errors

```zig
var action: std.posix.Sigaction = .{
    .handler = .{ .handler = onUsr1 },
    .mask = std.posix.sigemptyset(),
    .flags = 0,
};
std.posix.sigaction(.USR1, &action, null);
```

`sigaction` returns `void`. It used to return an error union, so `try` in
front of it is now an error about a non-error value. And a handler takes a
`std.posix.SIG` rather than a `c_int`:

```zig
fn onUsr1(sig: std.posix.SIG) callconv(.c) void
```

Every handler written before this change has the signature `fn (c_int)
callconv(.C) void` and does not compile. That is the good outcome. An enum
parameter also means a `switch` over the signal in a shared handler is
checked. And `.int` cannot be confused with the integer 10 on one platform and
30 on another.

## Set a flag. Do nothing else.

```zig
var caught: std.atomic.Value(u32) = .init(0);

fn onUsr1(_: std.posix.SIG) callconv(.c) void {
    caught.store(1, .seq_cst);
}
```

The handler interrupted arbitrary code. If that code was inside `malloc`,
holding the allocator's lock, and your handler allocates, it waits for a lock
held by the thread it is running on. That is a deadlock with one thread in it,
and it happens perhaps once in ten thousand runs, in production, under load.

The same applies to anything that takes a lock or allocates, which is most of
what you would want to do. `std.debug.print` locks standard error. A logger
allocates. A hash map insert may allocate. The set of calls that are safe here
is small and does not include the ones you reach for while debugging why the
handler is not working.

So the handler stores to an atomic and returns. Everything real happens in the
main loop, which reads the flag when it is between two units of work and can
afford to think. It is an atomic rather than a plain `bool` because the
handler runs between two instructions of code that may be reading the same
variable. A torn or reordered read there is a real bug on a weakly ordered
machine.

## Blocking defers, it does not discard

```zig
std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
try std.posix.raise(.USR1);   // pending, not delivered
std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
// handler runs here
```

A blocked signal is held pending until it is unblocked, and then delivered.
This is how a program protects a section that must not be interrupted without
losing the notification. It is also the mechanism behind `signalfd` and
`pidfd`. Those block a signal permanently and then read it as data on a
descriptor, turning an interruption into something a normal event loop can
wait on. That is what most servers actually do.

Pending is a bit, not a count. Ten `SIGUSR1`s raised while blocked deliver
once. A handler that increments a counter is counting deliveries, not signals,
and a program that needs to know how many things happened has to count them
somewhere else.

## Defaults you inherit

Every signal has a disposition before your program touches it, and for most of
them it is to terminate the process. `SIGUSR1` is the snippet's example: named
"user defined" and fatal by default, so a program that never installs a
handler dies when one arrives.

Three worth remembering:

| Signal | Default | Sent when |
| --- | --- | --- |
| `SIGINT` | terminate | someone pressed Ctrl-C |
| `SIGTERM` | terminate | something asked you to stop politely |
| `SIGPIPE` | terminate | you wrote to a pipe nobody is reading |

`SIGINT` and `SIGTERM` are the two a long-running program should handle, and
handling them means setting a flag that the main loop turns into a clean
shutdown. `SIGKILL` and `SIGSTOP` cannot be handled or blocked at all, which
is the guarantee that lets an operator stop a process that has stopped
listening.
