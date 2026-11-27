# Binary Files

> A small binary format with a header, written one field at a time, and a reader that checks each byte that it did not write.

A text file stores numbers as characters. The number 1200 is four bytes: `'1'`, `'2'`, `'0'`, `'0'`.

A binary file stores the number itself. As a `u32`, 1200 is also four bytes. But the bytes are the bits of the number, not digits.

Binary files are smaller and faster to read, because the program does not have to parse them. But a person cannot read them. Thus you must write down the format exactly.

The program below defines a small format for a list of players. It writes a file in that format and reads the file again. Then it gives the reader three bad files.

```zig
const std = @import("std");

const Io = std.Io;

// First, write down the format. All integers are little-endian.
//
//   header, 10 bytes
//     0  magic    4 bytes  "SCOR"
//     4  version  u16      1
//     6  count    u32      number of records
//
//   record, 9 bytes + name
//     0  id        u32
//     4  score     i32
//     8  name_len  u8
//     9  name      name_len bytes
const magic = "SCOR";
const version: u16 = 1;

const Player = struct {
    id: u32,
    score: i32,
    name: []const u8,
};

const players = [_]Player{
    .{ .id = 7, .score = 1200, .name = "ada" },
    .{ .id = 42, .score = -15, .name = "linus" },
    .{ .id = 300, .score = 0, .name = "grace" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Byte order.
    try out.print("1. the number 0x01020304 as four bytes\n", .{});
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, 0x01020304, endian);
        try out.print("   {t:<7} {x}\n", .{ endian, bytes });
    }

    // 2. Write the file and dump each byte.
    try out.print("2. scores.bin\n", .{});
    try save(io, dir, "scores.bin", &players);
    try hexDump(io, dir, "scores.bin", out);

    // 3. Read the file again.
    try out.print("3. read back\n", .{});
    try printFile(io, dir, "scores.bin", out);

    // 4. Three files that are wrong in different ways.
    try out.print("4. bad files\n", .{});
    var good: [64]u8 = undefined;
    const bytes = try dir.readFile(io, "scores.bin", &good);

    try dir.writeFile(io, .{ .sub_path = "photo.png", .data = "\x89PNG\r\n\x1a\n\x00\x00" });
    var newer = bytes[0..10].*;
    std.mem.writeInt(u16, newer[4..6], 2, .little);
    try dir.writeFile(io, .{ .sub_path = "newer.bin", .data = &newer });
    try dir.writeFile(io, .{ .sub_path = "cut.bin", .data = bytes[0 .. bytes.len - 4] });

    for ([_][]const u8{ "photo.png", "newer.bin", "cut.bin" }) |name| {
        try out.print("   {s}: ", .{name});
        if (printFile(io, dir, name, out)) |_| {} else |err| try out.print("{t}\n", .{err});
    }

    for ([_][]const u8{ "scores.bin", "photo.png", "newer.bin", "cut.bin" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn save(io: Io, dir: Io.Dir, name: []const u8, list: []const Player) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u32, @intCast(list.len), .little);

    for (list) |p| {
        try w.writeInt(u32, p.id, .little);
        try w.writeInt(i32, p.score, .little);
        try w.writeByte(@intCast(p.name.len));
        try w.writeAll(p.name);
    }
    try w.flush();
}

const FormatError = error{ NotScoresFile, UnsupportedVersion, Truncated, TooManyRecords, NameTooLong };

/// A record from the disk. The reader copies the name out of its buffer,
/// because the next read can write over that buffer.
const Record = struct {
    id: u32,
    score: i32,
    name_buf: [16]u8,
    name_len: u8,

    fn name(r: *const Record) []const u8 {
        return r.name_buf[0..r.name_len];
    }
};

const max_records = 8;

fn printFile(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [512]u8 = undefined;
    var fr = file.reader(io, &buf);

    var records: [max_records]Record = undefined;
    const n = readRecords(&fr.interface, &records) catch |err| switch (err) {
        // The file ended in the middle of a value. For a reader of a
        // format, this is a bad file, not the normal end of input.
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return fr.err.?,
        else => |e| return e,
    };

    // Act on the data only now, after the check of the full file.
    for (records[0..n]) |*rec| {
        var num: [12]u8 = undefined;
        const score = try std.mem.print(&num, "{d}", .{rec.score});
        try out.print("   id {d:>3}  score {s:>5}  {s}\n", .{ rec.id, score, rec.name() });
    }
}

fn readRecords(r: *Io.Reader, records: []Record) !usize {
    // Check what the file says it is, before the reader uses the bytes after it.
    if (!std.mem.eql(u8, try r.takeArray(4), magic)) return FormatError.NotScoresFile;
    if (try r.takeInt(u16, .little) != version) return FormatError.UnsupportedVersion;

    // `count` comes from the file. Thus it is untrusted, the same as all data.
    const count = try r.takeInt(u32, .little);
    if (count > records.len) return FormatError.TooManyRecords;

    for (records[0..count]) |*rec| {
        rec.id = try r.takeInt(u32, .little);
        rec.score = try r.takeInt(i32, .little);
        rec.name_len = try r.takeByte();
        if (rec.name_len > rec.name_buf.len) return FormatError.NameTooLong;
        @memcpy(rec.name_buf[0..rec.name_len], try r.take(rec.name_len));
    }
    return count;
}

fn hexDump(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var buf: [64]u8 = undefined;
    const bytes = try dir.readFile(io, name, &buf);
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        const row = bytes[offset..@min(offset + 16, bytes.len)];
        try out.print("   {x:0>4}  ", .{offset});
        for (row) |b| try out.print("{x:0>2} ", .{b});
        try out.splatByteAll(' ', (16 - row.len) * 3 + 1);
        for (row) |b| try out.writeByte(if (std.ascii.isPrint(b)) b else '.');
        try out.writeByte('\n');
    }
    try out.print("   {d} bytes\n", .{bytes.len});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.binary-files`)*

## Write the format first

Before the code, the snippet writes down the format in a comment.

```
//   header, 10 bytes
//     0  magic    4 bytes  "SCOR"
//     4  version  u16      1
//     6  count    u32      number of records
//
//   record, 9 bytes + name
//     0  id        u32
//     4  score     i32
//     8  name_len  u8
//     9  name      name_len bytes
```

Each byte has a position, a size and a meaning. All integers are little-endian.

This table is the format. The code only obeys the table. A program in a different language can read the file if it obeys the same table.

## Byte order

A `u32` is four bytes, and a computer can store the four bytes in two orders.

```
   little  04030201
   big     01020304
```

- Little-endian puts the smallest byte first. x86 and ARM computers use this order.
- Big-endian puts the largest byte first. Network protocols frequently use this order.

The two orders are equally correct. The important thing is that the format says which order it uses, and that the code gives the order on each read and write.

For this reason, `writeInt` and `takeInt` both take the byte order as an argument. There is no default.

## Write the file

```zig
fn save(io: Io, dir: Io.Dir, name: []const u8, list: []const Player) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u32, @intCast(list.len), .little);

    for (list) |p| {
        try w.writeInt(u32, p.id, .little);
        try w.writeInt(i32, p.score, .little);
        try w.writeByte(@intCast(p.name.len));
        try w.writeAll(p.name);
    }
    try w.flush();
}
```

*Quoted from the source: `save` from `snippets/24-files/binary-files.zig`.*

The program writes each field separately:

- `writeAll(magic)` writes the four letters `SCOR`.
- `writeInt(u16, version, .little)` writes the version as two bytes.
- The name is a string of any length. Thus the program first writes the length of the name as one byte, then the bytes of the name.

The name of this method is a length prefix. The length prefix tells the reader where one name ends and the next record starts.

Here is each byte of the file.

```
   0000  53 43 4f 52 01 00 03 00 00 00 07 00 00 00 b0 04  SCOR............
   0010  00 00 03 61 64 61 2a 00 00 00 f1 ff ff ff 05 6c  ...ada*........l
   0020  69 6e 75 73 2c 01 00 00 00 00 00 00 05 67 72 61  inus,........gra
   0030  63 65                                            ce
   50 bytes
```

You can find each field in the dump:

- `53 43 4f 52` is `SCOR`.
- `01 00` is version 1, and `03 00 00 00` is a count of 3. The small byte is first in the two values.
- Then the first record: id `07 00 00 00`, score `b0 04 00 00` (0x04b0 or 1200), name length `03`, and `ada`.

The score of Linus, -15, is `f1 ff ff ff`, because a computer stores negative numbers in two's complement.

## Why not write the struct directly

The program can copy the memory of a `Player` struct to the file in one call. That code is shorter, but it is incorrect.

A usual Zig struct has no fixed layout. The compiler can change the order of the fields and add padding. The integers in the struct are in the byte order of the computer that wrote them. Thus the bytes can change with a new compiler, a different target, or a different build mode.

[A Binary Wire Format](https://www.ziglang.in/learn/how-to/binary-roundtrip/) gives more information about this. The short rule: write the fields one at a time, and give the byte order each time.

## Read the file again

```zig
fn readRecords(r: *Io.Reader, records: []Record) !usize {
    // Check what the file says it is, before the reader uses the bytes after it.
    if (!std.mem.eql(u8, try r.takeArray(4), magic)) return FormatError.NotScoresFile;
    if (try r.takeInt(u16, .little) != version) return FormatError.UnsupportedVersion;

    // `count` comes from the file. Thus it is untrusted, the same as all data.
    const count = try r.takeInt(u32, .little);
    if (count > records.len) return FormatError.TooManyRecords;

    for (records[0..count]) |*rec| {
        rec.id = try r.takeInt(u32, .little);
        rec.score = try r.takeInt(i32, .little);
        rec.name_len = try r.takeByte();
        if (rec.name_len > rec.name_buf.len) return FormatError.NameTooLong;
        @memcpy(rec.name_buf[0..rec.name_len], try r.take(rec.name_len));
    }
    return count;
}
```

*Quoted from the source: `readRecords` from `snippets/24-files/binary-files.zig`.*

The reader obeys the same table, in the same order. But the reader does not trust the file. The file can contain any data: a different format, a newer version of this format, or a file that a copy operation cut short.

Thus the reader checks each value before it uses the value:

1. First the magic. If the first four bytes are not `SCOR`, the file is not a file of this format, and the reader stops.
2. Then the version. A file from a newer program can have fields that this reader does not know. Thus the reader also stops for a newer version.
3. Then the count. The count comes from the file. Thus the count is also not trusted.

A bad file can say that it holds four billion records. Thus the reader compares the count with the number of records that it has space for. The name length gets the same check against the size of `name_buf`.

## Three bad files

```
   photo.png: NotScoresFile
   newer.bin: UnsupportedVersion
   cut.bin: Truncated
```

- `photo.png` starts with the PNG signature. Thus the magic check rejects the file.
- `newer.bin` is the header of this format, with the version changed to 2.
- `cut.bin` is the file of this format without the last four bytes.

In `cut.bin`, the reader reads the first two records correctly. The third record ends in the middle of its name.

When too few bytes remain, `take` returns `error.EndOfStream`. In a text file, the end of the stream is normal. It means that the input is complete.

In the middle of a record, the end of the stream means that the file is bad. Thus `printFile` changes `EndOfStream` into the error of this format, `error.Truncated`.

## Check all data, then act

```zig
fn printFile(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [512]u8 = undefined;
    var fr = file.reader(io, &buf);

    var records: [max_records]Record = undefined;
    const n = readRecords(&fr.interface, &records) catch |err| switch (err) {
        // The file ended in the middle of a value. For a reader of a
        // format, this is a bad file, not the normal end of input.
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return fr.err.?,
        else => |e| return e,
    };

    // Act on the data only now, after the check of the full file.
    for (records[0..n]) |*rec| {
        var num: [12]u8 = undefined;
        const score = try std.mem.print(&num, "{d}", .{rec.score});
        try out.print("   id {d:>3}  score {s:>5}  {s}\n", .{ rec.id, score, rec.name() });
    }
}
```

*Quoted from the source: `printFile` from `snippets/24-files/binary-files.zig`.*

`printFile` first reads all records into an array. It prints only after `readRecords` checked the full file.

The first version of this program printed each record when it read the record. For `cut.bin`, the program printed two players and then reported the error.

In a real program, an action on each record when the record arrives can cause damage. For example, the action is "update the database" and not "print". Then the program saves half of a bad file before it finds the error.

Thus read and check all data first. Act only when all of the data is valid.

`readRecords` has one more detail. `take(name_len)` returns a slice of the buffer of the reader, and the next read can write over that buffer. Thus the program copies the name into `name_buf` with `@memcpy`. [Read Line by Line](https://www.ziglang.in/learn/files/read-lines/#keep-a-line) has the same rule for lines.
