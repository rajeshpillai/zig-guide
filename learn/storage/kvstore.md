# A Write-Ahead Log

> Write down what you are about to do, then do it. Recovery is replaying the note.

The last chapter ended on a problem it could not solve: two files that have to
agree, and a crash between writing one and the other. That is the general
shape, and it has nothing to do with files specifically. It is any change that
is not a single indivisible act.

The answer is old, simple, and used by every database, every journalling
filesystem, and most message queues. **Write down what you are about to do,
then do it.** If the power goes out before you finish, the note is still there
when you come back, and you do the thing again.

That note is a **write-ahead log**, and the whole of recovery is reading it.

## The program

```zig
const std = @import("std");

/// Adler-style: two running sums, one of the bytes and one of the sums, so
/// the order of the bytes matters. Hand-rolled because this track builds what
/// it uses, and because the property that matters is easy to state: change any
/// byte and the number changes.
fn checksum(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// `<checksum>|<op>|<key>|<value>\n`. The checksum comes first so it can be
/// read before the thing it describes, and the newline is the frame: a torn
/// write leaves a last line without one.
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

/// Rebuild the store by replaying the log, and stop at the first record that
/// does not verify. Stopping rather than skipping is the important half: a
/// log is a sequence, and a record after a broken one may depend on it.
pub fn replay(wal: []const u8) Recovery {
    var store: Store = .{};
    var applied: usize = 0;
    var offset: usize = 0;
    // How far the log is known good. Advanced only after a record has been
    // verified *and* applied, so a record that fails its checksum is counted
    // as discarded rather than silently consumed.
    var good: usize = 0;

    while (offset < wal.len) {
        // No newline means the process died mid-write. Everything before is
        // intact, and this partial record never happened.
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

    // The power goes out part way through the last write. The bytes that
    // reached the disk are a line with no newline on the end.
    const torn = full[0 .. full.len - 8];
    try report(out, "crash during the last write", torn);

    // A byte flips in the middle of the log. The newline framing cannot see
    // this; the checksum can.
    var damaged: [1024]u8 = undefined;
    @memcpy(damaged[0..full.len], full);
    // Inside the second record, so the third and fourth are still perfectly
    // readable and are refused anyway.
    damaged[30] = 'X';
    try report(out, "a byte corrupted in the second record", damaged[0..full.len]);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`20-storage.kvstore`)*

## What just happened

**A clean shutdown replayed all four records.** Nothing surprising, and it is
worth noticing what it means: the in-memory store was rebuilt from the log
alone. The log is the database; the hash map is a cache of it that happens to
be fast.

**The crash lost the record that was mid-write, and nothing else.** Truncating
the log to simulate a power failure left a final line with no newline, replay
stopped there, and the first three records were fine. `c` is absent, which is
correct: that write never completed, so it never happened.

This is the property that makes a WAL work. A partially written record at the
**end** of an append-only file is always detectable, because a record is
complete only once its terminator has been written. Nothing before it can be
affected, because nothing before it was touched.

**The corrupted byte was caught by the checksum, and replay stopped.** The
newline framing cannot see this: the record has its terminator, it is just
wrong. Only the checksum notices.

And look at what stopping cost: records three and four were perfectly readable
and were refused anyway. That is deliberate. A log is a **sequence**, and a
record after a damaged one may depend on the one that was lost. Applying the
readable remainder gives you a store that never existed at any point in time.
That is worse than a store missing its tail, because you cannot tell by
looking.

## What this program cannot show you

`fsync`. Writing to a file puts the bytes in the operating system's page
cache, where they will reach the disk when it gets around to it. If the power
fails in between, the write is gone, and the log will happily tell you on
recovery that it never happened.

`fsync` is the call that says "actually put it on the platter, and do not
return until you have". A WAL without it is a WAL that protects you from your
process dying and not from the machine dying. It is also expensive, which is
why databases have a durability setting, and why the fast one is fast.

The reason this page cannot demonstrate it is that there is no disk here. That
is worth saying rather than quietly omitting: the mechanism above is complete
and the guarantee is not.

## Check yourself

The log grows forever. Every `set` appends, even to a key written a thousand
times. What stops a real system from filling the disk?

A **checkpoint**. Recovery then means loading the last checkpoint and
replaying only what came after it. That also makes startup fast: without
checkpoints, a database that has been running for a year replays a year of
history every time it starts.

This is the same idea as the tombstones from the first chapter arriving at a
different scale. An append-only structure needs a periodic process to reclaim
what is dead, and in an LSM tree that process is called compaction.

## If you have written C

`write` then `fsync`, and the two hazards are ordering and lying.

Ordering: the log write must reach the disk **before** the change it
describes. Not at the same time, before. If the database file is updated first
and the machine dies, the log has no record of a change that has already
happened, and recovery cannot undo it. That is why it is called write-*ahead*,
and getting it backwards produces a system that is correct in every test and
wrong exactly once.

Lying: `fsync` has historically returned success without the data being
durable on several combinations of filesystem, controller and drive with write
caching enabled. PostgreSQL has a well-known write-up of discovering that
error handling on a failed `fsync` also differed by kernel version, in ways
that could lose data silently. The lesson is not to distrust `fsync`, it is
that durability is a property of the whole stack rather than of one call.

Next: a query engine, which is the first thing here that has to decide *how*
to answer rather than what.
