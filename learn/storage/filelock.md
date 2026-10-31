# Two Writers, One File

> What a lost update looks like, and the lock that prevents it.

To increment a counter in a file, you need three operations, not one:

1. Read the value.
2. Add one.
3. Write the value back.

There is a gap between the read and the write. During that gap, the value on
disk is stale, and a different writer can read it.

Two writers, each with 200 increments, must give 400. They will not.

## The program

This program has no Run button. It needs real threads and a real filesystem.
Thus the build makes the program for the host and runs it there. The program
also has no pinned output. That is unusual on this site, and the chapter
explains the reason.

```zig
const std = @import("std");

const rounds = 200;

/// Read a counter, add one, and write it back. That is three steps. The other
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

    // The files are in the working directory, with names that no other code
    // uses. The program removes them at the end. A new directory is one more
    // thing to remove on each exit path, and this demo does not need one.
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

*This program needs real threads and a real filesystem. Thus CI builds and runs it on the host. The output is intentionally different on each run. Thus, different from each other snippet here, it has no expected output to check. (`20-storage.filelock`)*

This is one run on the computer that built this page:

```
two threads, 200 increments each

without a lock: 183, expected 400
  updates lost: true

with a lock:    400, expected 400
  updates lost: false
```

## What the program did

**More than half of the increments disappeared.** The program did not crash,
report an error or write a log line. The file contains a number that is too
small, and no part of the system saw the problem. Each lost update was the same
sequence: one thread read 91, the other thread read 91, and both threads wrote
92.

**If you run the program again, you get a different number.** Because the
result changes, races are expensive to fix. You can bisect a bug that occurs
again in the same way. This bug gives a different value each time. It
disappears under a debugger, because the timing changes. It is worst on the
computer with the most cores, and that computer is usually production.

The value changes on each run. This is also the reason that this snippet has
no expected output. If the build pinned one number, the nightly would fail on a tree with no
changes. That failure would be a false report from the build, not a bug in the
code.

**The lock made the result exact.** The result is 400 each time. The fix makes
the read-modify-write indivisible. The fix works because the gap between the
read and the write does not exist now. The gap does not only become smaller.

**The lock here is in-process.** A `std.Io.Mutex` controls threads in one
program, and it knows nothing about a second copy of the program. For a second
copy, the operating system must hold the lock, thus you must lock the file. The
same three-line fix applies, at a level where each process can see it.

## Check yourself

Suppose that you make the write atomic. For example, you write to a temporary
file and rename it over the original. Does this fix the problem?

The answer is no. With an atomic rename, no reader ever sees a half-written
file. That solves a real problem, but a different problem. It does nothing for
this problem, because both threads still read 91 before either thread writes.
The lost update occurs between the read and the write. A change to the write
cannot close a gap that opened before the write.

An atomic write and exclusive access across the read-modify-write are two
separate properties, and a store needs both. Some systems confuse the two
properties. These systems have careful `rename` steps and corrupted counters.

## If you know C

There are two calls, and their differences are important:

- `flock` locks the open file description. Thus a child gets the lock across
  `fork`, and the kernel releases the lock when the last descriptor closes.
- `fcntl` locks are per-process. The kernel releases them when any descriptor
  for the file closes, also a descriptor that you opened separately. This second
  behaviour surprises many people.

On Linux, both locks are **advisory** by default. They work only if each writer
asks for the lock. This is intentional. File locks control programs that agree
to use them. No mode protects a file from a program that ignores the lock.

The other hazard that is specific to C: `read` and `write` on the same
descriptor share a file offset. Two threads that use one `fd` mix their
positions. Thus the fix in C is usually `pread`/`pwrite`. These calls take an
offset, and they do not change the shared offset.

Next: [an index](https://www.ziglang.in/learn/storage/indexes/). With an index, a read of one key
does not need a read of the full file.
