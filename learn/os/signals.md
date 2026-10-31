# Signals

> A handler interrupts you between two instructions. Set a flag and return.

A signal is a call from the operating system to a function in your program,
at a time that you did not select. A signal is not a queue that you poll, and
it is not a message that you receive.

The kernel stops your thread between two instructions. The handler runs on
the stack of that thread. Then the next instruction runs, as if nothing
occurred.

```zig
const std = @import("std");
const posix = std.posix;

/// The handler here does one thing: it sets this flag. The flag is a
/// `std.atomic.Value`, because the handler can run between any two
/// instructions of the code below. A write to a plain `bool` there is a data
/// race with the code that the handler interrupted.
var caught: std.atomic.Value(u32) = .init(0);

fn onUsr1(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    caught.store(1, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // `sigaction` returns nothing. In the past, it returned an error union,
    // and the handler took a `c_int`. Both changed. Thus a handler from an
    // older tutorial does not compile. It does not fail at run time.
    var action: posix.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.USR1, &action, null);

    try out.print("caught before: {d}\n", .{caught.load(.seq_cst)});
    try posix.raise(.USR1);
    try out.print("caught after:  {d}\n\n", .{caught.load(.seq_cst)});

    // A block delays a signal. It does not discard the signal. If you raise
    // USR1 while it is blocked, it stays pending. The kernel sends it
    // immediately when you unblock it.
    caught.store(0, .seq_cst);
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .USR1);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    try posix.raise(.USR1);
    try out.print("while blocked: {d}\n", .{caught.load(.seq_cst)});
    try out.flush();

    posix.sigprocmask(posix.SIG.UNBLOCK, &mask, null);
    try out.print("once unblocked: {d}\n\n", .{caught.load(.seq_cst)});

    // Give the signal back to the default disposition of the kernel. For USR1,
    // that default is "terminate the process". Thus a USR1 kills a program
    // that never installed a handler for it.
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

*CI builds and runs this snippet natively. A WASI sandbox has no signals, because it has no kernel to send them. (`14-os.signals`)*

## Two things changed, and both cause compile errors

```zig
var action: std.posix.Sigaction = .{
    .handler = .{ .handler = onUsr1 },
    .mask = std.posix.sigemptyset(),
    .flags = 0,
};
std.posix.sigaction(.USR1, &action, null);
```

`sigaction` returns `void`. In the past, it returned an error union. Thus a
`try` in front of the call now causes an error about a value that is not an
error. Also, a handler now takes a `std.posix.SIG`, not a `c_int`:

```zig
fn onUsr1(sig: std.posix.SIG) callconv(.c) void
```

Each handler from before this change has the signature `fn (c_int)
callconv(.C) void`, and it does not compile. Here, a compile error is the
better result.

The enum parameter has two more advantages:

- The compiler checks a `switch` over the signal in a shared handler.
- You cannot confuse `.USR1` with the integer 10 on one platform and 30 on a
  different platform.

## Set a flag. Do nothing else.

```zig
var caught: std.atomic.Value(u32) = .init(0);

fn onUsr1(_: std.posix.SIG) callconv(.c) void {
    caught.store(1, .seq_cst);
}
```

The handler interrupted code that can be anywhere. Assume that the code was
inside `malloc` and held the lock of the allocator. If your handler allocates,
the handler waits for a lock that its own thread holds. The result is a
deadlock with one thread. It can occur one time in ten thousand runs, in
production, under load.

The same problem applies to all calls that take a lock or allocate, and these
are most of the calls that you want. `std.debug.print` locks standard error. A
logger allocates. An insert into a hash map can allocate. Only a small set of
calls is safe in a handler. That set does not include the calls that you use
to find why the handler does not work.

Thus the handler stores to an atomic and returns. All the real work occurs in
the main loop. The main loop reads the flag between two units of work, when it
has time to handle the flag.

The flag is an atomic, not a plain `bool`. The reason is that the handler runs
between two instructions of code that can read the same variable. On a
weakly ordered computer, a torn or reordered read at that point is a real bug.

## A block delays a signal and does not discard it

```zig
std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
try std.posix.raise(.USR1);   // pending, not delivered
std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
// handler runs here
```

The kernel holds a blocked signal as pending until you unblock it. Then the
kernel sends the signal. With this method, a program protects a section from
interruptions, and it does not lose the notification.

The same method is the base of `signalfd`. Block a signal permanently, then
read it as data on a descriptor. Then a normal event loop can wait for the
interruption. Most servers handle signals in this way.

Pending is one bit, not a count. If you raise ten `SIGUSR1` signals while the
signal is blocked, the kernel sends the signal one time. A handler that
increments a counter counts deliveries, not signals. If a program must know
how many events occurred, the program must count the events in a different
place.

## Defaults that you inherit

Each signal has a disposition before your program changes it. For most
signals, the disposition is to terminate the process.

`SIGUSR1` is the example in the snippet. Its name means "user defined", and by
default it is fatal. Thus if a program never installs a handler, the program
stops when a `SIGUSR1` arrives.

Remember these three:

| Signal | Default | Sent when |
| --- | --- | --- |
| `SIGINT` | terminate | someone pressed Ctrl-C |
| `SIGTERM` | terminate | something asked you to stop politely |
| `SIGPIPE` | terminate | you wrote to a pipe that has no reader |

A program that runs for a long time must handle `SIGINT` and `SIGTERM`. To
handle them, set a flag. The main loop then changes the flag into a clean
shutdown.

You cannot handle or block `SIGKILL` and `SIGSTOP`. Thus an operator can
always stop a process that does not respond.
