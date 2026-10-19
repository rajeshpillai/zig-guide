//! title: Signals
//! native
//! A handler interrupts you between two instructions. Set a flag. Do nothing else.

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
