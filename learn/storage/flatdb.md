# An Append-Only Record Store

> Never modify written data. A delete is a record that you add.

The simplest database is a file that you only append to. To write a record,
seek to the end and write. The write does not touch the data that is already on
disk.

This rule seems to be a limitation, but it gives three benefits together:

- A write that crashes in the middle leaves a partial record at the end. All
  the data before the partial record does not change.
- Two readers can read while a writer appends, because the bytes that they
  read never change.
- The full history stays in the file. Thus the file can answer the question
  "what did this look like on Tuesday".

The rule also causes two problems, and each log-structured store must solve
them. This chapter is about those two problems.

## The program

```zig
const std = @import("std");

/// One record on each line, with `|` between the fields. The separator is
/// the main design decision. It makes a second decision necessary: what
/// occurs when a value contains `|`.
pub const Record = struct {
    op: enum { put, delete },
    key: []const u8,
    value: []const u8,
};

/// Escape the separator and the newline, so that a record can hold them.
/// Without this function, a value that contains `|` silently becomes two
/// fields. You cannot see the corruption until some code reads the value.
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

/// Read the log forward, and keep the last record for each key. A delete is
/// a record in the file. An append-only file has no other way to show a
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

    // A buffer in place of the file. Each write is an append. No code here
    // can seek backwards, and this demo stays within that limit.
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

## What the program did

**The program wrote `alice` two times, and the read gives the second value.**
No code updated the first record. The reader scans forward and keeps the last
record for each key. Thus "update" means "append a newer record".

The old
value is still in the file. The old value can be a useful audit log. It can
also be a leak, if the old value was a secret.

**The program deleted `bob` with a new record.** The store never modifies the
file, thus it also cannot remove data. The store must write a removal as a new
record. That record is a **tombstone**, and all log-structured databases have
tombstones: LSM trees, Kafka topics, Git. For the same reason, a delete in such
a store makes the file larger.

**The value for `carol` contained a `|` and a newline, and the value stayed
correct.** The separator causes this problem. If `|` is the field separator, a
value that contains `|` becomes two fields. A value that contains a newline
becomes two records. Neither case gives an error. Both cases give incorrect data
on read, and the data looks correct.

The escape scheme has three rules. The design of the scheme had to be complete
before the program wrote the first record. If you change the scheme later, all
the files that exist are in the old format. For this reason, real formats use one of
two methods:

- Escape the data. CSV does this, and doubles the quotes.
- Put a length prefix on the data. Write the byte count, then the bytes, and
  never scan for a delimiter.

[Binary protocols](https://www.ziglang.in/learn/networking/binary-protocols/) use length prefixes.
Length prefixes are the better answer when a human does not read the file.

**A read of one key read the full file.** Each lookup is a full scan. With
five records, the scan costs almost nothing. With five million records, the
scan is the full cost of the system. The solution is an index, two chapters
after this one.

## Check yourself

The store keeps the *last* record for a key. What must change, so that the
store can answer "what was the value for alice before she became an architect"?

The answer: almost nothing. The information is already in the file, and the
reader discards it. To return a history, collect the matches and do not write
over one variable. Because the store keeps the history, append-only stores are
a good fit for these uses:

- Audit trails.
- Event sourcing.
- All uses where you must answer "how did the data get to this state".

A store that updates data in place loses this history.

## If you know C

The append is `open(path, O_WRONLY | O_APPEND)` and a `write`. `O_APPEND` does
more work than it seems to do. It makes the seek to the end and the write into
one atomic operation. Thus two processes that append to the same file cannot
interleave a record. Without `O_APPEND`, you seek, then you write, and the
problem of the next chapter occurs immediately.

That atomic operation has two limits:

- A `write` can return after it wrote fewer bytes than you asked for. The rest
  of the bytes need a second call, and a different writer can write before that
  call.
- On NFS, the guarantee does not apply. The protocol has no append, thus the
  client simulates the append, and the race occurs again.

For this reason, the program builds each record in memory and writes it one
time.

Next: [what occurs when two writers meet](https://www.ziglang.in/learn/storage/filelock/). `O_APPEND`
solved that problem here, but the program did not ask it to.
