# Two Writers, One File

> What a lost update looks like, and the lock that prevents it.

Incrementing a counter in a file is three operations, not one. Read the value,
add one, write it back. Between the read and the write there is a gap, and for
the length of that gap the value on disk is stale and somebody else may be
reading it.

Two writers, each doing 200 increments, should leave 400. They will not.

## The program

No Run button: this needs real threads and a real filesystem, so it is built
for the host and executed there. It also has no pinned output, which is
unusual here and is the point of the chapter.

```zig
const std = @import("std");

const rounds = 200;

/// Read a counter, add one, write it back. Three steps, and the gap between
/// the read and the write is where the other writer gets in.
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

    // The working directory, with names nothing else uses, cleaned up at the
    // end. Creating a directory is one more thing to tidy away on every exit
    // path, and this demo does not need one.
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

**Over half the increments vanished.** Not a crash, not an error, no log line.
The file contains a number that is simply too small, and nothing in the system
noticed. Every one of those lost updates was a thread reading 91, another
thread reading 91, and both writing 92.

**Run it again and you get a different number.** This is the property that
makes races expensive. A bug that reproduces is a bug you can bisect. This one
is a different value every time, disappears under a debugger because the
timing changes, and is worst on the machine with the most cores, which is
production. It is also why this snippet has no expected output. Pinning one
number would make our nightly fail on an unchanged tree, and that would be the
build lying rather than the code.

**The lock made it exact.** Not "more accurate": 400, every time. Making the
read-modify-write indivisible is the whole fix, and the reason it works is
that the gap stops existing rather than getting smaller.

**The lock here is in-process.** A `std.Io.Mutex` coordinates threads in one
program and knows nothing about a second copy of the program. For that you
need the operating system to hold the lock, which means locking the file
itself. The same three-line fix applies, at a level where every process can
see it.

## Check yourself

Would making the write atomic fix this, for example by writing to a temporary
file and renaming it over the original?

No, and the reason is worth being precise about. An atomic rename means no
reader ever sees a half-written file, which is a real and different problem
solved. It does nothing about this one, because both threads still read 91
before either writes. The lost update happens between the read and the write,
and no amount of care in the write closes a gap that opened earlier.

Atomicity of the write and exclusivity across the read-modify-write are two
separate properties, and a store needs both. Confusing them is how systems end
up with careful `rename` dances and corrupted counters.

## If you have written C

There are two calls, and they differ in ways that matter. `flock` locks the
open file description, so it is inherited across `fork` and released when the
last descriptor closes. `fcntl` locks are per-process, and are released when
any descriptor for the file is closed, even one you opened separately. That
second behaviour has surprised a lot of people.

Both are **advisory** on Linux by default, meaning they only work if every
writer asks. That is not a flaw so much as a contract. File locking
coordinates cooperating programs, and there is no mode that protects a file
from a program determined to ignore you.

The other C-specific hazard is that `read` and `write` on the same descriptor
share a file offset. Two threads using one `fd` interleave their positions, so
the fix in C is usually `pread`/`pwrite`, which take an offset and leave the
shared one alone.

Next: [an index](https://www.ziglang.in/learn/storage/indexes/), so that reading one key stops
meaning reading the whole file.
