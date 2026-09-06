# An Append-Only Record Store

> Never modify what is written. Deleting is something you add.

The simplest database is a file you only ever append to. Writing a record
means seeking to the end and writing; nothing already on disk is touched.

That constraint sounds like a limitation and buys three things immediately. A
write that crashes half way leaves a partial record at the end, and everything
before it is untouched. Two readers can read while a writer appends, because
the bytes they are reading never change under them. And the whole history is
still there, so "what did this look like on Tuesday" is a question the file
can answer.

It also creates two problems that every log-structured store has to solve, and
this chapter is really about those.

## The program

```zig
const std = @import("std");

/// One record per line, fields separated by `|`. The separator is the whole
/// design decision, and it forces the next one: what happens when a value
/// contains it.
pub const Record = struct {
    op: enum { put, delete },
    key: []const u8,
    value: []const u8,
};

/// Escape the separator and the newline, so a record can hold either.
/// Without this a value containing `|` silently becomes two fields, and the
/// corruption is invisible until something reads it back.
fn writeEscaped(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '|' => try out.writeAll("\\p"),
        '\n' => try out.writeAll("\\n"),
        '\\' => try out.writeAll("\\\\"),
        else => try out.writeByte(c),
    };
}

fn unescape(dest: []u8, text: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (n == dest.len) return error.TooLong;
        if (text[i] == '\\' and i + 1 < text.len) {
            dest[n] = switch (text[i + 1]) {
                'p' => '|',
                'n' => '\n',
                else => '\\',
            };
            i += 2;
        } else {
            dest[n] = text[i];
            i += 1;
        }
    }
    return dest[0..n];
}

pub fn append(log: *std.Io.Writer, record: Record) !void {
    try log.writeAll(if (record.op == .put) "put|" else "del|");
    try writeEscaped(log, record.key);
    try log.writeAll("|");
    try writeEscaped(log, record.value);
    try log.writeAll("\n");
}

/// Read the log forward, keeping the last thing said about each key. A delete
/// is a record, not the absence of one, which is the only way an append-only
/// file can express removal.
pub fn lookup(log: []const u8, key: []const u8, scratch: []u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var used: usize = 0;

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '|');
        const op = fields.next() orelse continue;
        const raw_key = fields.next() orelse continue;
        const raw_value = fields.next() orelse "";

        var key_buf: [128]u8 = undefined;
        const this_key = try unescape(&key_buf, raw_key);
        if (!std.mem.eql(u8, this_key, key)) continue;

        if (std.mem.eql(u8, op, "del")) {
            result = null;
        } else {
            const value = try unescape(scratch[used..], raw_value);
            used += value.len;
            result = value;
        }
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A buffer standing in for the file. Every write is an append; nothing
    // here can seek backwards, which is the constraint being explored.
    var file: [1024]u8 = undefined;
    var log: std.Io.Writer = .fixed(&file);

    try append(&log, .{ .op = .put, .key = "alice", .value = "engineer" });
    try append(&log, .{ .op = .put, .key = "bob", .value = "designer" });
    try append(&log, .{ .op = .put, .key = "alice", .value = "architect" });
    try append(&log, .{ .op = .delete, .key = "bob", .value = "" });
    try append(&log, .{ .op = .put, .key = "carol", .value = "a|b\nc" });

    const written = log.buffered();
    try out.print("the log, {d} bytes:\n", .{written.len});
    try out.print("{s}\n", .{written});

    var scratch: [256]u8 = undefined;
    var live: usize = 0;
    for ([_][]const u8{ "alice", "bob", "carol", "dave" }) |key| {
        if (try lookup(written, key, &scratch)) |value| {
            live += 1;
            try out.print("{s: <6} -> \"{s}\"\n", .{ key, value });
        } else {
            try out.print("{s: <6} -> (absent)\n", .{key});
        }
    }

    try out.print("\n5 records written, {d} keys live, and the file only ever grew\n", .{live});
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`20-storage.flatdb`)*

## What just happened

**`alice` was written twice and reads back as the second value.** Nothing
updated the first record. The reader scans forward and keeps the last thing
said about each key, so "update" is a word for "append something newer". The
old value is still in the file, which is either an audit log or a leak
depending on what was in it.

**`bob` was deleted by adding a record.** A file that cannot modify cannot
remove, so removal has to be something you write down. That record is a
**tombstone**, and every log-structured database has them: LSM trees, Kafka
topics, Git. It is also why deleting from such a store makes it bigger.

**`carol`'s value contained a `|` and a newline, and survived.** This is the
problem the separator creates. Choosing `|` as a field separator means a value
containing `|` splits into two fields, and a value containing a newline
becomes two records. Neither corrupts loudly; both produce plausible garbage
on read.

The escape scheme is three rules and had to be designed before the first
record was written, because changing it later means every existing file is in
the old format. That is why real formats either escape (CSV, doubling quotes),
or length-prefix (write the byte count, then the bytes, and never scan for a
delimiter at all). Length prefixing is what [binary
protocols](https://www.ziglang.in/learn/networking/binary-protocols/) do and is the better answer
whenever the file is not meant to be read by a human.

**Reading one key read the whole file.** Every lookup is a full scan. At five
records that is free; at five million it is the entire cost of the system, and
the fix is an index, which is two chapters away.

## Check yourself

The store keeps the *last* record for a key. What would have to change for it
to answer "what was alice's value before she became an architect"?

Almost nothing, which is the interesting part. The information is already in
the file; the reader is throwing it away. Returning a history means collecting
matches instead of overwriting a variable. That is the property that makes
append-only stores the natural fit for audit trails, event sourcing, and
anything where "how did we get here" is a real question. It is lost the moment
you switch to a store that updates in place.

## If you have written C

The append is `open(path, O_WRONLY | O_APPEND)` and a `write`, and `O_APPEND`
is doing more work than it looks. It makes the seek-to-end and the write a
single atomic operation, so two processes appending to the same file cannot
interleave a record. Without it you would seek, then write, and the next
chapter's problem arrives immediately.

That atomicity has a limit worth knowing. It holds for a single write up to
the pipe buffer size, and a record split across two calls can be interleaved
with somebody else's. Which is why records here are built in memory and
written once.

Next: [what happens when two writers meet](https://www.ziglang.in/learn/storage/filelock/), which is
the problem `O_APPEND` was quietly solving.
