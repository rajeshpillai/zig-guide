# Random Access

> A file of records of fixed size. Read record N and not the records before it, change one record in place, and make the file larger and smaller.

The earlier chapters read a file from the start to the end. That method works for text, where a line can have any length. To find line 500, the program must read the 499 lines before it.

If all records in a file have the same size, the program does not have to read the earlier records. Record 500 starts at byte `500 * size`. The program can read the record directly. It can also change the record and not touch the remainder of the file. The name of this method is random access.

The program below keeps a small file of bank accounts. Each account is 16 bytes.

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

    // 1. Write five records. Each record is at its own offset.
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

    // 3. Change one record in place. No other byte in the file moves.
    try out.print("3. update record 1\n", .{});
    var a1 = try readRecord(io, file, 1);
    a1.balance -= 750;
    try writeRecord(io, file, 1, a1);
    const updated = try readRecord(io, file, 1);
    try out.print("   record 1 is now id {d}  balance {d}\n", .{ updated.id, updated.balance });
    try list(io, file, out, false);

    // 4. Write past the end. A read of the gap gives zero bytes.
    try out.print("4. write record 7\n", .{});
    try writeRecord(io, file, 7, .{ .id = 107, .balance = 99, .active = true });
    try list(io, file, out, true);

    // 5. A reader that seeks, and not an offset on each call.
    try out.print("5. seek to the last record\n", .{});
    {
        var buf: [record_size]u8 = undefined;
        var reader = file.reader(io, &buf);
        const size = try reader.getSize();
        try reader.seekTo(size - record_size);
        const last = Account.decode(try reader.interface.takeArray(record_size));
        try out.print("   size {d}, seekTo({d}), id {d}\n", .{ size, size - record_size, last.id });
    }

    // 6. Make the file smaller to remove the last records.
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

```zig
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
```

*Quoted from the source: `Account` from `snippets/24-files/random-access.zig`.*

A comment at the top of the snippet gives the layout, the same as the format in [Binary Files](https://www.ziglang.in/learn/files/binary-files/).

- `encode` changes an `Account` into exactly 16 bytes.
- `decode` changes 16 bytes back into an `Account`.

The balance is an `i64` count of cents, not a float. Money in a float gets rounding errors.

The record does not use bytes 13 to 15, and `encode` always sets them to zero. Unused bytes give a later version of the format space for a new field, with no change to the record size.

The bytes start from `@splat(0)`. Thus the program does not write old memory contents to the file.

## Read and write at an offset

```zig
fn writeRecord(io: Io, file: Io.File, index: usize, a: Account) !void {
    const bytes = a.encode();
    try file.writePositionalAll(io, &bytes, index * record_size);
}
```

*Quoted from the source: `writeRecord` from `snippets/24-files/random-access.zig`.*

`writePositionalAll(io, bytes, offset)` writes the bytes at that offset. The function does not use the current position of the file, and it does not move the position. Thus the offset of record `index` is `index * record_size`, and that is the full calculation.

```zig
fn readRecord(io: Io, file: Io.File, index: usize) !Account {
    var bytes: [record_size]u8 = undefined;
    const n = try file.readPositionalAll(io, &bytes, index * record_size);
    if (n != record_size) return error.NoSuchRecord;
    return Account.decode(&bytes);
}
```

*Quoted from the source: `readRecord` from `snippets/24-files/random-access.zig`.*

`readPositionalAll` does the same for a read. It returns the number of bytes that it read. If the record is after the end of the file, that count is less than 16, and the function returns `error.NoSuchRecord`.

```
2. record 3 only
   read 16 bytes at offset 48: id 103
```

The program never read records 0, 1 and 2. For a file of five records, this saves nothing. For a file of five million records, it is the difference between one read and five million reads.

## Change one record

```
3. update record 1
   record 1 is now id 101  balance 1250
   80 bytes, 5 records
```

The program reads record 1 and subtracts 750 from the balance. Then it writes the 16 bytes back to the same offset.

The file is still 80 bytes. The program did not write the bytes before or after record 1 again.

Compare this with a text file. If a balance changes from `1000` to `999`, the line becomes one character shorter, and each byte after the line must move. With records of fixed size, a new value always fits in the old space.

## Write past the end

The file has five records, with the numbers 0 to 4. Now the program writes record 7.

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

The write succeeds, and the file becomes 128 bytes.

The program never wrote records 5 and 6. A read of each of these records gives 16 zero bytes. Thus their id is 0. The program uses id 0 for an empty slot. For this reason, real ids start at 100.

On most Linux and macOS filesystems, a gap of this type uses no space on disk. The filesystem records that the range is zero and does not store the range. The name of a file with gaps of this type is a sparse file.

## A reader that seeks

`readPositionalAll` takes the offset on each call. A `File.Reader` can do the same thing with a position that it keeps.

```
5. seek to the last record
   size 128, seekTo(112), id 107
```

1. `reader.getSize()` gets the file size.
2. `reader.seekTo(size - record_size)` moves the reader to the start of the last record.
3. `takeArray(record_size)` reads the 16 bytes from that position.

- To read some records in a sequence after one seek, use the reader.
- When each read is at a different position, use the positional calls.

## Make the file smaller

`file.setLength(io, 5 * record_size)` cuts the file to 80 bytes.

```
6. setLength to 5 records
   80 bytes, 5 records
```

Records 5, 6 and 7 are gone.

`setLength` can also make a file longer. The new bytes are zero, the same as the gap in part 4 of the output.

## A record that is too short

For example, the program stops unexpectedly in the middle of the write of a new record. Only part of the record gets to the disk. The last step of the program simulates this failure: it writes 6 bytes at the end.

```
7. a torn write
   file length 86
   PartialRecord
```

86 is not a multiple of 16.

```zig
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

*Quoted from the source: `list` from `snippets/24-files/random-access.zig`.*

`list` first does this check, with `size % record_size`, and returns `error.PartialRecord`.

Without the check, the function calculates 5 records and ignores the six extra bytes. That hides the problem: the file is damaged, and the program never tells you.

A real program must decide what to do next:

- It can cut the file back to the last full record with `setLength`.
- It can refuse to start until a person examines the file.

In the two cases, the program must first find the problem.

[An Append-Only Record Store](https://www.ziglang.in/learn/storage/flatdb/) recovers from exactly this case. [A Write-Ahead Log](https://www.ziglang.in/learn/storage/kvstore/) handles a crash in the middle of a change.

## The size of a length

`file.length` returns a `u64`. `list` divides the length by 16. Then it changes the result to a `usize` with `std.math.cast`.

[Open, Read, Close](https://www.ziglang.in/learn/files/open-read-close/#open-a-handle) explains why. On `wasm32`, a `usize` is 32 bits, and a file can be larger than 32 bits can count.
