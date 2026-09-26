# Two Writers, One File

> What a lost update looks like, and the lock that prevents it.

Incrementing a counter in a file is three operations, not one. Read the value,
add one, write it back. Between the read and the write there is a gap, and for
the length of that gap the value on disk is stale and somebody else may be
reading it.

Two writers, each doing 200 increments, should leave 400. They will not.

## The program

No Run button: this needs real threads and a real filesystem, so it is built
for the host and executed there. It also has no pinned output. That is
unusual on this site, and the chapter explains why.

```zig
const std = @import("std");

const rounds = 200;

/// Read a counter, add one, write it back. That is three steps, and the other
/// writer can change the file between the read and the write.
fn increment(dir: *std.Io.Dir, io: std.Io, name: []const u8, lock: ?*std.Io.Mutex) void {
    for (0..rounds) |_| {
        if (lock) |m| m.lock(io) catch return;
        defer if (lock) |m| m.unlock(io);

        var buf: [32]u8 = undefined;
        const current = blk: {
            const file = dir.openFile(io, name, .{}) catch break :blk @as(u64, 0);
            defer file.close(io);
            var reader = file.readerStreaming(io, &buf);
            const text = reader.interface.allocRemaining(std.heap.page_allocator, .unlimited) catch break :blk @as(u64, 0);
            defer std.heap.page_allocator.free(text);
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
        };

        var out_buf: [32]u8 = undefined;
        const text = std.mem.print(&out_buf, "{d}", .{current + 1}) catch continue;

        const file = dir.createFile(io, name, .{ .truncate = true }) catch continue;
        defer file.close(io);
        var writer = file.writerStreaming(io, &buf);
        writer.interface.writeAll(text) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn run(dir: *std.Io.Dir, io: std.Io, name: []const u8, lock: ?*std.Io.Mutex) !u64 {
    {
        const file = try dir.createFile(io, name, .{ .truncate = true });
        defer file.close(io);
        var buf: [8]u8 = undefined;
        var writer = file.writerStreaming(io, &buf);
        try writer.interface.writeAll("0");
        try writer.interface.flush();
    }

    const a = try std.Thread.spawn(.{}, increment, .{ dir, io, name, lock });
    const b = try std.Thread.spawn(.{}, increment, .{ dir, io, name, lock });
    a.join();
    b.join();

    var buf: [32]u8 = undefined;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &buf);
    const text = try reader.interface.allocRemaining(std.heap.page_allocator, .unlimited);
    defer std.heap.page_allocator.free(text);
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // Files go in the working directory, with names nothing else uses, and
    // are removed at the end. A new directory would be one more thing to
    // remove on every exit path, and this demo does not need one.
    var dir = std.Io.Dir.cwd();
    defer dir.deleteFile(io, "storage-unlocked.tmp") catch {};
    defer dir.deleteFile(io, "storage-locked.tmp") catch {};

    const expected = rounds * 2;

    const lost = try run(&dir, io, "storage-unlocked.tmp", null);
    try out.print("two threads, {d} increments each\n\n", .{rounds});
    try out.print("without a lock: {d}, expected {d}\n", .{ lost, expected });
    try out.print("  updates lost: {}\n\n", .{lost < expected});

    var mutex: std.Io.Mutex = .init;
    const kept = try run(&dir, io, "storage-locked.tmp", &mutex);
    try out.print("with a lock:    {d}, expected {d}\n", .{ kept, expected });
    try out.print("  updates lost: {}\n", .{kept < expected});

    try out.flush();
}
```

*Needs real threads and a real filesystem, so CI builds and runs it on the host. Its output deliberately differs on every run, so unlike every other snippet here it has no expected output to check. (`20-storage.filelock`)*

A run on the machine that built this page:

```
two threads, 200 increments each

without a lock: 183, expected 400
  updates lost: true

with a lock:    400, expected 400
  updates lost: false
```

## What just happened

**Over half the increments vanished.** The program did not crash, report an
error or write a log line. The file contains a number that is too small, and
nothing in the system noticed. Every one of those lost updates was a thread reading 91, another
thread reading 91, and both writing 92.

**Run it again and you get a different number.** A changing result
makes races expensive to fix. A bug that reproduces is a bug you can bisect.
This one gives a different value every time. It disappears under a debugger,
because the timing changes. It is worst on the machine with the most cores,
which is usually production. The changing value is also why this snippet has no
expected output. Pinning one number would make our nightly fail on an unchanged
tree. That failure would be a false report from the build, not a bug in the
code.

**The lock made it exact.** The result is 400 every time. The fix is to make
the read-modify-write indivisible. It works because the gap between the read
and the write no longer exists. It does not just get smaller.

**The lock here is in-process.** A `std.Io.Mutex` coordinates threads in one
program and knows nothing about a second copy of the program. For that you
need the operating system to hold the lock, which means locking the file
itself. The same three-line fix applies, at a level where every process can
see it.

## Check yourself

Would making the write atomic fix this, for example by writing to a temporary
file and renaming it over the original?

No. An atomic rename means no reader ever sees a half-written file. That solves
a real problem, but a different one. It does nothing about this one, because both threads still read 91
before either writes. The lost update happens between the read and the write.
Changing how the write works cannot close a gap that opened before it.

Atomicity of the write and exclusivity across the read-modify-write are two
separate properties, and a store needs both. Systems that confuse them end up
with careful `rename` steps and corrupted counters.

## If you have written C

There are two calls, and they differ in ways that matter. `flock` locks the
open file description, so it is inherited across `fork` and released when the
last descriptor closes. `fcntl` locks are per-process, and are released when
any descriptor for the file is closed, even one you opened separately. That
second behaviour surprises many people.

Both are **advisory** on Linux by default, meaning they only work if every
writer asks for the lock. This is by design. File locking coordinates programs
that agree to use it. No mode protects a file from a program that ignores the
lock.

The other C-specific hazard is that `read` and `write` on the same descriptor
share a file offset. Two threads using one `fd` interleave their positions, so
the fix in C is usually `pread`/`pwrite`, which take an offset and leave the
shared one alone.

Next: [an index](https://www.ziglang.in/learn/storage/indexes/), so that reading one key stops
meaning reading the whole file.
