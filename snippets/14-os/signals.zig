//! title: Signals
//! native
//! A handler interrupts you between two instructions. Set a flag; do nothing else.

const std = @import("std");
const posix = std.posix;

/// The handler here does one thing: it sets this flag. It is a
/// `std.atomic.Value` because the handler can run between any two instructions
/// of the code below. A plain `bool` written there is a data race with
/// whatever that code was doing.
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
    // an older tutorial fails to compile instead of misbehaving at run time.
    var action: posix.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.USR1, &action, null);

    try out.print("caught before: {d}\n", .{caught.load(.seq_cst)});
    try posix.raise(.USR1);
    try out.print("caught after:  {d}\n\n", .{caught.load(.seq_cst)});

    // Blocking a signal delays it. The signal is not discarded. USR1 raised
    // while blocked stays pending, and is delivered as soon as it is unblocked.
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
    // that default is "terminate the process". That default is why an
    // unhandled USR1 kills a program that never installed a handler for it.
    var default: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.USR1, &default, null);
    try out.writeAll("USR1 restored to its default disposition\n");

    try out.flush();
}
