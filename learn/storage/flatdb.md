# An Append-Only Record Store

> Never modify what is written. Deleting is something you add.

The simplest database is a file you only ever append to. Writing a record
means seeking to the end and writing; nothing already on disk is touched.

This rule sounds like a limitation, but it gives three benefits at once. A
write that crashes half way leaves a partial record at the end, and everything
before it is untouched. Two readers can read while a writer appends, because
the bytes they are reading never change under them. And the whole history is
still there, so "what did this look like on Tuesday" is a question the file
can answer.

It also creates two problems that every log-structured store has to solve.
This chapter is about those two problems.

## The program

```zig
const std = @import("std");

/// One record per line, fields separated by `|`. The separator is the main
/// design decision. It forces a second decision: what happens when a value
/// contains `|`.
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

/// Read the log forward, keeping the last record for each key. A delete is
/// written as a record. An append-only file has no other way to express
/// removal.
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

    // A buffer used in place of the file. Every write is an append. Nothing
    // here can seek backwards, and this demo works within that limit.
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
old value is still in the file. That can be a useful audit log, or a leak if
the old value was a secret.

**`bob` was deleted by adding a record.** The store never modifies the file,
so it cannot remove anything either. Removal has to be written as a new record. That record is a
**tombstone**, and every log-structured database has them: LSM trees, Kafka
topics, Git. For the same reason, deleting from such a store makes the file bigger.

**`carol`'s value contained a `|` and a newline, and survived.** The separator
causes this problem. Choosing `|` as a field separator means a value
containing `|` splits into two fields, and a value containing a newline
becomes two records. Neither case causes an error. Both give wrong data on read that looks
correct.

The escape scheme is three rules and had to be designed before the first
record was written, because changing it later means every existing file is in
the old format. For this reason, real formats either escape (CSV, doubling quotes),
or length-prefix (write the byte count, then the bytes, and never scan for a
delimiter at all). Length prefixing is what [binary
protocols](https://www.ziglang.in/learn/networking/binary-protocols/) do and is the better answer
whenever the file is not meant to be read by a human.

**Reading one key read the whole file.** Every lookup is a full scan. At five
records the scan costs almost nothing. At five million it is the entire cost of
the system. The fix is an index, which is two chapters away.

## Check yourself

The store keeps the *last* record for a key. What would have to change for it
to answer "what was alice's value before she became an architect"?

Almost nothing. The information is already in the file. The reader throws it
away. Returning a history means collecting matches instead of overwriting a
variable. Because the history is kept, append-only stores are a natural fit for audit trails, event sourcing, and
anything where you need to answer "how did we get here". A store that updates
in place loses this history.

## If you have written C

The append is `open(path, O_WRONLY | O_APPEND)` and a `write`, and `O_APPEND`
does more work than it seems to. It makes the seek-to-end and the write a
single atomic operation, so two processes appending to the same file cannot
interleave a record. Without it you would seek, then write, and the next
chapter's problem arrives immediately.

That atomicity has two limits. A `write` can return having
written fewer bytes than you asked for, and the rest is a second call that
another writer can get in front of. On NFS it does not hold at all: the
protocol has no append, so the client simulates it and the race comes back.
For this reason, the program builds each record in memory and writes it once.

Next: [what happens when two writers meet](https://www.ziglang.in/learn/storage/filelock/), which is
the problem `O_APPEND` solved here without being asked.
