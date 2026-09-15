# Recipe: A File-Backed To-Do Store

> Fixed-size records on disk, updated in place by id with positional reads and writes.

## The problem

You want to persist a list of items and update any one of them without
rewriting the whole file. The trick is to make every record the same size.
Then record `N` lives at a fixed byte offset, so reading or updating it is one
positional operation, not a scan. This is the idea under every fixed-page
database file.

## The plan

1. Define the record as an `extern struct`, so its byte layout is fixed and
   identical on every write.
2. Add by appending at the current end of file.
3. Read or update record `N` at `offset = (N - 1) * @sizeOf(Record)`.
4. Update in place: read the slot, change a field, write it back to the same
   offset.

```zig
const std = @import("std");

// An extern struct has a fixed, predictable layout, so every record is the same
// number of bytes on disk. That is what makes record N reachable directly at
// offset N * @sizeOf(Record), with no index and no scan.
const Record = extern struct {
    id: u32,
    done: bool,
    len: u8,
    text: [64]u8,
};

fn addTask(io: std.Io, file: std.Io.File, text: []const u8) !u32 {
    const end = try file.length(io);
    const id: u32 = @intCast(end / @sizeOf(Record) + 1);

    var rec: Record = .{ .id = id, .done = false, .len = @intCast(@min(text.len, 64)), .text = @splat(0) };
    @memcpy(rec.text[0..rec.len], text[0..rec.len]);

    // Append by writing at the current end of file.
    try file.writePositionalAll(io, std.mem.asBytes(&rec), end);
    return id;
}

fn toggle(io: std.Io, file: std.Io.File, id: u32) !void {
    const offset = (id - 1) * @sizeOf(Record);

    // Read one record straight from its slot, flip the flag, write it back to
    // the same slot. No rewrite of the whole file.
    var rec: Record = undefined;
    _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
    rec.done = !rec.done;
    try file.writePositionalAll(io, std.mem.asBytes(&rec), offset);
}

fn list(io: std.Io, file: std.Io.File, out: *std.Io.Writer) !void {
    const end = try file.length(io);
    var offset: u64 = 0;
    while (offset < end) : (offset += @sizeOf(Record)) {
        var rec: Record = undefined;
        _ = try file.readPositionalAll(io, std.mem.asBytes(&rec), offset);
        try out.print("{d}  [{s}]  {s}\n", .{
            rec.id,
            if (rec.done) "x" else " ",
            rec.text[0..rec.len],
        });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // A fresh database each run (createFile truncates by default), removed at
    // the end so the example leaves nothing behind.
    var dir = std.Io.Dir.cwd();
    const file = try dir.createFile(io, "todo-demo.db", .{ .read = true });
    defer dir.deleteFile(io, "todo-demo.db") catch {};
    defer file.close(io);

    _ = try addTask(io, file, "write the recipe");
    const verify = try addTask(io, file, "verify it");
    _ = try addTask(io, file, "ship it");

    try toggle(io, file, verify); // mark item 2 done

    try out.print("record size: {d} bytes\n\n", .{@sizeOf(Record)});
    try list(io, file, out);

    try out.flush();
}
```

*Uses the real filesystem, so CI builds and runs it natively. The browser WASI sandbox has no directories to open. (`06-cookbook.todo-store`)*

## Fixed size is the whole trick

The record is an `extern struct`, which pins its layout: an id, a done flag, a
length byte, and 64 bytes of text. That is the same 72 bytes every time. The
extra two are alignment padding, and they are harmless because every offset is
computed from `@sizeOf`. Because the size is constant, the file is an array on
disk. Item 3 is at offset `2 * 72`, always, so `toggle` jumps straight there.
A variable-length format, JSON lines for instance, loses this: you would have
to read from the start to find where record 3 begins.

## Positional I/O, not seek

Since Zig 0.16 the filesystem lives behind the `Io` interface, and random
access is done with `readPositionalAll` and `writePositionalAll`, each taking
an explicit offset. There is no separate seek call to forget: the offset is an
argument to the read or write itself. The older `seekTo` plus `getPos` dance
is gone. `file.length(io)` gives the end of file, which is both the append
point and the loop bound for listing.

`std.mem.asBytes(&rec)` is what bridges the struct and the file: it views the
record as the `[N]u8` the I/O calls want, with no copy. Reading does the
reverse, filling a `Record` straight from the bytes on disk. That only works
because the layout is fixed, which is why the struct is `extern`.

## Update in place

`toggle` is the payoff. It reads the one record at its offset, flips `done`,
and writes those same bytes back to the same offset. A real store would add a
free list for deletions, and an index for lookups by something other than id.
The core, a fixed record addressed by offset, does not change.

## Variations

- **Delete:** mark a record with a tombstone flag rather than removing it, so
  later offsets stay valid; compact later.
- **Larger text:** raise the `text` array, or store long values in a second
  file and keep an offset and length in the record.
- **Endianness:** `extern` layout is host byte order. To move the file between
  machines, write fields explicitly like
  [the binary round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/) does.
- **A real database engine:** [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/) gives you
  the same on-disk durability with SQL on top.
