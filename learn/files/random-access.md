# Random Access

> A file of fixed-size records. Read record N without reading the ones before it, change one in place, and grow and shrink the file.

The chapters so far read a file from the start to the end.

That works for text, where a line can be any length.

To find line 500, we have to read the 499 lines before it.

If every record in a file has the same size, we do not need to.

Record 500 starts at byte `500 * size`.

We can read it directly, or change it and leave the rest of the file alone.

This is called random access.

The program below keeps a small file of bank accounts, 16 bytes each.

```zig
const std = @import("std");

const Io = std.Io;

// One record is 16 bytes, little-endian, at offset `index * 16`.
//
//   0  id       u32
//   4  balance  i64   in cents
//   12 active   u8    1 or 0
//   13 unused   3 bytes, always zero
const record_size = 16;

const Account = struct {
    id: u32,
    balance: i64,
    active: bool,

    fn encode(a: Account) [record_size]u8 {
        var bytes: [record_size]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], a.id, .little);
        std.mem.writeInt(i64, bytes[4..12], a.balance, .little);
        bytes[12] = @intFromBool(a.active);
        return bytes;
    }

    fn decode(bytes: *const [record_size]u8) Account {
        return .{
            .id = std.mem.readInt(u32, bytes[0..4], .little),
            .balance = std.mem.readInt(i64, bytes[4..12], .little),
            .active = bytes[12] != 0,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, "accounts.db", .{ .read = true });
    defer file.close(io);

    // 1. Write five records, each at its own offset.
    try out.print("1. five records\n", .{});
    for (0..5) |i| {
        const a: Account = .{ .id = @intCast(100 + i), .balance = @intCast(1000 * (i + 1)), .active = true };
        try writeRecord(io, file, i, a);
    }
    try list(io, file, out, true);

    // 2. Read one record directly.
    try out.print("2. record 3 only\n", .{});
    const a3 = try readRecord(io, file, 3);
    try out.print("   read 16 bytes at offset {d}: id {d}\n", .{ 3 * record_size, a3.id });

    // 3. Change one record in place. Nothing else in the file moves.
    try out.print("3. update record 1\n", .{});
    var a1 = try readRecord(io, file, 1);
    a1.balance -= 750;
    try writeRecord(io, file, 1, a1);
    const updated = try readRecord(io, file, 1);
    try out.print("   record 1 is now id {d}  balance {d}\n", .{ updated.id, updated.balance });
    try list(io, file, out, false);

    // 4. Write past the end. The gap reads back as zero bytes.
    try out.print("4. write record 7\n", .{});
    try writeRecord(io, file, 7, .{ .id = 107, .balance = 99, .active = true });
    try list(io, file, out, true);

    // 5. A reader that seeks, instead of an offset on every call.
    try out.print("5. seek to the last record\n", .{});
    {
        var buf: [record_size]u8 = undefined;
        var reader = file.reader(io, &buf);
        const size = try reader.getSize();
        try reader.seekTo(size - record_size);
        const last = Account.decode(try reader.interface.takeArray(record_size));
        try out.print("   size {d}, seekTo({d}), id {d}\n", .{ size, size - record_size, last.id });
    }

    // 6. Shrink the file to drop the tail.
    try out.print("6. setLength to 5 records\n", .{});
    try file.setLength(io, 5 * record_size);
    try list(io, file, out, false);

    // 7. A length that is not a whole number of records.
    try out.print("7. a torn write\n", .{});
    try file.writePositionalAll(io, "\x69\x00\x00\x00\x00\x00", 5 * record_size);
    try out.print("   file length {d}\n", .{try file.length(io)});
    if (list(io, file, out, false)) |_| {} else |err| try out.print("   {t}\n", .{err});

    try dir.deleteFile(io, "accounts.db");
}

fn writeRecord(io: Io, file: Io.File, index: usize, a: Account) !void {
    const bytes = a.encode();
    try file.writePositionalAll(io, &bytes, index * record_size);
}

fn readRecord(io: Io, file: Io.File, index: usize) !Account {
    var bytes: [record_size]u8 = undefined;
    const n = try file.readPositionalAll(io, &bytes, index * record_size);
    if (n != record_size) return error.NoSuchRecord;
    return Account.decode(&bytes);
}

fn list(io: Io, file: Io.File, out: *Io.Writer, show_records: bool) !void {
    const size = try file.length(io);
    if (size % record_size != 0) return error.PartialRecord;
    const count = std.math.cast(usize, size / record_size) orelse return error.FileTooBig;
    try out.print("   {d} bytes, {d} records\n", .{ size, count });
    if (!show_records) return;
    for (0..count) |i| {
        const a = try readRecord(io, file, i);
        if (a.id == 0) {
            try out.print("     [{d}] empty\n", .{i});
        } else {
            try out.print("     [{d}] id {d}  balance {d}\n", .{ i, a.id, a.balance });
        }
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.random-access`)*

## One record, 16 bytes

<SnippetSource name="24-files.random-access" decl="Account" />

The layout is written in a comment at the top of the snippet, like the format in [Binary Files](https://www.ziglang.in/learn/files/binary-files/).

`encode` turns an `Account` into exactly 16 bytes.

`decode` turns 16 bytes back into an `Account`.

The balance is an `i64` count of cents, not a float. Money in a float gets rounding errors.

Bytes 13 to 15 are not used, and `encode` always sets them to zero.

Unused bytes give a later version of the format room for a new field without changing the record size.

Starting from `@splat(0)` also means no leftover memory is written to the file.

## Reading and writing at an offset

<SnippetSource name="24-files.random-access" decl="writeRecord" />

`writePositionalAll(io, bytes, offset)` writes the bytes at that offset.

It does not use the file's current position, and it does not move it.

So the offset of record `index` is `index * record_size`, and that is the whole calculation.

<SnippetSource name="24-files.random-access" decl="readRecord" />

`readPositionalAll` is the same for reading.

It returns how many bytes it read.

If the record is past the end of the file, that count is less than 16, and we return `error.NoSuchRecord`.

```
2. record 3 only
   read 16 bytes at offset 48: id 103
```

Records 0, 1 and 2 were never read.

For a file of five records that saves nothing. For a file of five million, it is the difference between one read and five million.

## Changing one record

```
3. update record 1
   record 1 is now id 101  balance 1250
   80 bytes, 5 records
```

We read record 1, subtract 750 from the balance, and write the 16 bytes back to the same offset.

The file is still 80 bytes.

Nothing before or after record 1 was rewritten.

Compare this with a text file.

If a balance changes from `1000` to `999`, the line gets one character shorter, and every byte after it has to move.

With fixed-size records, a new value always fits in the old space.

## Writing past the end

The file has five records, numbered 0 to 4. Now we write record 7.

```
4. write record 7
   128 bytes, 8 records
     [0] id 100  balance 1000
     [1] id 101  balance 1250
     [2] id 102  balance 3000
     [3] id 103  balance 4000
     [4] id 104  balance 5000
     [5] empty
     [6] empty
     [7] id 107  balance 99
```

The write succeeds, and the file grows to 128 bytes.

Records 5 and 6 were never written.

They read back as 16 zero bytes each, so their id is 0.

The program uses id 0 to mean an empty slot, which is why real ids start at 100.

On most Linux and macOS filesystems, a gap like this takes no space on disk. The filesystem remembers that the range is zero and does not store it.

A file with gaps like this is called a sparse file.

## A reader that seeks

`readPositionalAll` takes the offset on every call.

A `File.Reader` can do the same thing with a position it remembers.

```
5. seek to the last record
   size 128, seekTo(112), id 107
```

`reader.getSize()` asks for the file size.

`reader.seekTo(size - record_size)` moves the reader to the start of the last record.

Then `takeArray(record_size)` reads the 16 bytes from there.

Use the reader when we read several records in a row after one seek. Use the positional calls when every read is at a different place.

## Shrinking the file

`file.setLength(io, 5 * record_size)` cuts the file to 80 bytes.

```
6. setLength to 5 records
   80 bytes, 5 records
```

Records 5, 6 and 7 are gone.

`setLength` can also make a file longer. The new bytes are zero, like the gap in section 4.

## A record that was cut short

Say the program crashes in the middle of writing a new record.

Only part of the record reaches the disk.

The last step simulates that by writing 6 bytes at the end.

```
7. a torn write
   file length 86
   PartialRecord
```

86 is not a multiple of 16.

<SnippetSource name="24-files.random-access" decl="list" />

`list` checks this first, with `size % record_size`, and returns `error.PartialRecord`.

Without the check, it would compute 5 records, and the six extra bytes would be ignored.

That hides the problem: the file is damaged, and the program never says so.

A real program has to decide what to do next.

It can cut the file back to the last whole record with `setLength`, or refuse to start until a person looks at it.

Either way, it has to notice first.

[An Append-Only Record Store](https://www.ziglang.in/learn/storage/flatdb/) recovers from exactly this case, and [A Write-Ahead Log](https://www.ziglang.in/learn/storage/kvstore/) handles a crash in the middle of a change.

## The size of a length

`file.length` returns a `u64`. `list` divides it by 16 and converts the result to a `usize` with `std.math.cast`.

[Open, Read, Close](https://www.ziglang.in/learn/files/open-read-close/#opening-a-handle) explains why. On `wasm32` a `usize` is 32 bits, and a file can be bigger than that.
