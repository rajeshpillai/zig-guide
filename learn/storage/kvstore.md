# A Write-Ahead Log

> Write down what you will do, then do it. Recovery is a replay of the note.

The last chapter ended on a problem that it could not solve: two files that
must agree, and a crash between the two writes. This problem is not specific to
files. It occurs with each change that is not one indivisible action.

The answer is old and simple. All databases, all journalling filesystems and
most message queues use it. **Write down what you will do, then do it.** If the
power fails before you finish, the note is still there when the program starts
again. Then you do the change again.

That note is a **write-ahead log**. Recovery is a read of the note.

## The program

```zig
const std = @import("std");

/// Adler-style: two sums, one of the bytes and one of the sums. Thus the
/// order of the bytes is important. The function is hand-written because this
/// track builds the parts that it uses. The necessary property is easy to
/// state: if you change a byte, the number changes.
fn checksum(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// `<checksum>|<op>|<key>|<value>\n`. The checksum is first, so that a reader
/// can read it before the data that it describes. The newline marks the end
/// of a record. Thus a write that stopped in the middle leaves a last line
/// without a newline.
pub fn append(wal: *std.Io.Writer, op: []const u8, key: []const u8, value: []const u8) !void {
    var body: [256]u8 = undefined;
    const payload = try std.mem.print(&body, "{s}|{s}|{s}", .{ op, key, value });
    try wal.print("{d}|{s}\n", .{ checksum(payload), payload });
}

pub const Store = struct {
    keys: [32][]const u8 = undefined,
    values: [32][]const u8 = undefined,
    count: usize = 0,

    fn set(s: *Store, key: []const u8, value: []const u8) !void {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                s.values[i] = value;
                return;
            }
        }
        if (s.count == s.keys.len) return error.Full;
        s.keys[s.count] = key;
        s.values[s.count] = value;
        s.count += 1;
    }

    fn remove(s: *Store, key: []const u8) void {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                s.keys[i] = s.keys[s.count - 1];
                s.values[i] = s.values[s.count - 1];
                s.count -= 1;
                return;
            }
        }
    }

    pub fn get(s: Store, key: []const u8) ?[]const u8 {
        for (s.keys[0..s.count], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return s.values[i];
        }
        return null;
    }
};

pub const Recovery = struct { store: Store, applied: usize, discarded: usize };

/// Build the store again from a replay of the log. Stop at the first record
/// that fails verification. Do not skip the record and continue, because a
/// log is a sequence. A record after a broken record can depend on it.
pub fn replay(wal: []const u8) Recovery {
    var store: Store = .{};
    var applied: usize = 0;
    var offset: usize = 0;
    // The end of the part of the log that is known good. The value moves
    // only after the program verifies *and* applies a record. Thus a record
    // that fails its checksum counts as discarded, and is not silently used.
    var good: usize = 0;

    while (offset < wal.len) {
        // No newline means that the process stopped during a write. All the
        // data before the partial record is intact. The replay ignores the
        // partial record, as if the program never wrote it.
        const end = std.mem.findScalarPos(u8, wal, offset, '\n') orelse break;
        const line = wal[offset..end];
        offset = end + 1;

        const bar = std.mem.findScalar(u8, line, '|') orelse break;
        const declared = std.fmt.parseInt(u32, line[0..bar], 10) catch break;
        const payload = line[bar + 1 ..];
        if (checksum(payload) != declared) break;

        var fields = std.mem.splitScalar(u8, payload, '|');
        const op = fields.next() orelse break;
        const key = fields.next() orelse break;
        const value = fields.next() orelse "";

        if (std.mem.eql(u8, op, "set")) {
            store.set(key, value) catch break;
        } else {
            store.remove(key);
        }
        applied += 1;
        good = offset;
    }

    return .{ .store = store, .applied = applied, .discarded = wal.len - good };
}

fn report(out: *std.Io.Writer, label: []const u8, wal: []const u8) !void {
    const r = replay(wal);
    try out.print("{s}\n", .{label});
    try out.print("  {d} records applied, {d} trailing bytes discarded\n", .{ r.applied, r.discarded });
    for ([_][]const u8{ "a", "b", "c" }) |key| {
        try out.print("  {s} -> {s}\n", .{ key, r.store.get(key) orelse "(absent)" });
    }
    try out.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var file: [1024]u8 = undefined;
    var wal: std.Io.Writer = .fixed(&file);

    try append(&wal, "set", "a", "one");
    try append(&wal, "set", "b", "two");
    try append(&wal, "set", "a", "uno");
    try append(&wal, "set", "c", "three");
    const full = wal.buffered();

    try out.print("the log:\n{s}\n", .{full});
    try report(out, "clean shutdown", full);

    // The power fails during the last write. The bytes that got to the disk
    // are a line with no newline at the end.
    const torn = full[0 .. full.len - 8];
    try report(out, "crash during the last write", torn);

    // A byte changes in the middle of the log. The newline framing cannot
    // see this change, but the checksum can see it.
    var damaged: [1024]u8 = undefined;
    @memcpy(damaged[0..full.len], full);
    // Inside the second record. The third and fourth records are still
    // readable, but the replay refuses them.
    damaged[30] = 'X';
    try report(out, "a byte corrupted in the second record", damaged[0..full.len]);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`20-storage.kvstore`)*

## What the program did

**A clean shutdown replayed all four records.** The program built the
in-memory store again from the log alone. The log is the database. The
in-memory store is a fast cache of the log.

**The crash lost the record that was in the middle of a write, and nothing
else.** To simulate a power failure, the program truncated the log. This left
a last line with no newline. The replay stopped there, and the first three
records were correct. `c` is absent, and that is correct: that write did not
complete, thus it did not occur.

A WAL works because of this property. When the process stops, you can find a
partial record at the **end** of an append-only file. A record is complete only
after the program writes its terminator. The data before the partial record
does not change, because no write touched that data.

**The checksum found the corrupted byte, and the replay stopped.** The newline
framing cannot see this problem. The record has its terminator, but its content
is incorrect. Only the checksum sees the problem.

The stop had a cost. Records three and four were readable, but the replay
refused them. This is intentional. A log is a **sequence**, and a record after
a damaged record can depend on the lost record. If you apply the readable
records that remain, you get a store that never existed at any time.

A store without its last records is the better result. A store that you build
from the readable records that are left looks correct, and you cannot see that it
is incorrect.

## What this program cannot show you

`fsync`. A write to a file puts the bytes in the page cache of the operating
system. The kernel writes them to the disk later, at a time that it selects. If
the power fails between these two times, the write is lost. On recovery, the
log shows that the write did not occur.

`fsync` is the call that says "write this to the disk now, and do not return
until the data is on the disk". A WAL without `fsync` protects you when your
process stops, but not when the computer stops. `fsync` is also slow. For this
reason, databases have a durability setting, and the fast setting is fast.

This page cannot demonstrate `fsync`, because there is no disk here. The
mechanism above is complete, but the durability guarantee is not complete.

## Check yourself

The log grows forever. Each `set` appends, also for a key that the program
wrote a thousand times. In a real system, what prevents a full disk?

The answer: a **checkpoint**. Then recovery loads the last checkpoint, and
replays only the records after the checkpoint. A checkpoint also makes the start
fast. Without checkpoints, a database that ran for a year must replay a year of
history each time it starts.

This is the same idea as the tombstones from the first chapter, at a larger
scale. An append-only structure needs a periodic process to get back the space
of dead records. In an LSM tree, the name of that process is compaction.

## If you know C

In C, the sequence is `write` and then `fsync`. The two hazards are order and
false success.

**Order:** the log write must get to the disk **before** the change that it
describes. It must come before the change, not at the same time. Suppose the
program updates the database file first, and the computer stops. Then the log
has no record of a change that already occurred, and recovery cannot undo the
change. For this reason, the name is write-*ahead*.

If the order is incorrect,
the system passes each test. Then it loses data the first time that the
computer stops at the incorrect moment.

**False success:** in the past, `fsync` sometimes returned success when the data
was not durable. This occurred on several combinations of filesystem,
controller and drive, with write caching on. PostgreSQL has a well-known report
about a related discovery. The error handling on a failed `fsync` was also
different in different kernel versions, and some versions could lose data
silently. Thus `fsync` alone does not make data durable. The filesystem, the
controller and the drive must also keep their promise.

Next: a query engine. The query engine is the first part here that must decide
*how* to answer, not only what to answer.
