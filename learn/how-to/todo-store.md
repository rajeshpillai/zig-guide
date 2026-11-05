# Recipe: A File-Backed To-Do Store

> Records of fixed size on disk, updated in place by id with positional reads and writes.

When all records are the same size, a store on disk in Zig can update one record and not write the full file again. Record `N` is at `(N - 1) * @sizeOf(Record)`. `readPositionalAll` and `writePositionalAll` read and write at that offset.

## The problem

You want to store a list of items on disk. You also want to update one item, and not write the full file again.

With records of fixed size, a read or an update of one record is one positional operation, not a scan. Each database file with pages of fixed size uses the same idea.

## The plan

1. Define the record as an `extern struct`. Thus its byte layout is fixed and identical on each write.
2. To add a record, append it at the current end of the file.
3. Read or update record `N` at its fixed offset.
4. To update in place, read the slot, change a field, and write the slot again to the same offset.

```zig
const std = @import("std");

// An extern struct has a fixed, predictable layout. Thus each record has the
// same number of bytes on disk. The program can read record N directly at
// offset (N - 1) * @sizeOf(Record), with no index and no scan.
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

    // To append, write at the current end of the file.
    try file.writePositionalAll(io, std.mem.asBytes(&rec), end);
    return id;
}

fn toggle(io: std.Io, file: std.Io.File, id: u32) !void {
    const offset = (id - 1) * @sizeOf(Record);

    // Read one record from its slot, toggle the flag, and write the record
    // again to the same slot. The program does not write the rest of the file.
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

    // A new database on each run (by default, createFile truncates the file).
    // The program removes the file at the end, thus the example leaves no file.
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

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.todo-store`)*

## Why all records are the same size

The record is an `extern struct`, which fixes its layout: an id, a done flag, a length byte and 64 bytes of text. The record is 72 bytes each time.

The two extra bytes are alignment padding. They cause no problem, because the code computes each offset from `@sizeOf`.

The size is constant. Thus the file is an array on disk. Item 3 is always at offset `2 * 72`, and `toggle` goes directly to that offset.

A format with records of different lengths, for example JSON lines, does not have this property. To find the start of record 3, you must read from the start of the file.

## Positional I/O, not seek

Since Zig 0.16, the filesystem is behind the `Io` interface. For random access, use `readPositionalAll` and `writePositionalAll`. Each function takes an explicit offset.

There is no separate seek call that you can forget, because the offset is an argument to the read or the write. Zig removed the older `seekTo` and `getPos` functions. `file.length(io)` gives the end of the file. That value is the append point, and also the loop limit for the list.

`std.mem.asBytes(&rec)` connects the struct and the file. It shows the record as the `[N]u8` that the I/O calls need, with no copy. A read does the opposite: it fills a `Record` directly from the bytes on disk.

These two operations work only because the layout is fixed, and `extern` fixes the layout.

## Update in place

`toggle` uses all of these parts together. It reads the one record at its offset, changes `done` to the opposite value, and writes the same bytes again to the same offset.

A real store adds a free list for deletions, and an index to find records by a value other than the id. The core does not change: a fixed record at a known offset.

## Variations

- **Delete:** put a tombstone flag on a record, and do not remove the record. Then the offsets after it stay valid. Compact the file at a later time.
- **Larger text:** make the `text` array larger. Or store long values in a second file, and keep an offset and a length in the record.
- **Endianness:** the `extern` layout uses the byte order of the host. To move the file between machines, write the fields explicitly, as [the binary round-trip recipe](https://www.ziglang.in/learn/how-to/binary-roundtrip/) does.
- **A real database engine:** [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/) gives you the same durability on disk, with SQL on top.
