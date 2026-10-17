# Binary Files

> A small binary format with a header, written one field at a time, and a reader that checks every byte it did not write.

A text file stores numbers as characters.

The number 1200 is four bytes: `'1'`, `'2'`, `'0'`, `'0'`.

A binary file stores the number itself.

As a `u32`, 1200 is also four bytes, but they are the bits of the number, not digits.

Binary files are smaller and faster to read, because there is nothing to parse.

But a person cannot read them, so the format has to be written down exactly.

The program below defines a small format for a list of players, writes a file in it, and reads it back.

Then it gives the reader three broken files.

```zig
const std = @import("std");

const Io = std.Io;

// The format, on paper first. All integers are little-endian.
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

    // 2. Write the file and dump every byte.
    try out.print("2. scores.bin\n", .{});
    try save(io, dir, "scores.bin", &players);
    try hexDump(io, dir, "scores.bin", out);

    // 3. Read it back.
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

/// A record read from disk. The name is copied out of the reader's buffer,
/// because the next read can overwrite that buffer.
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
        // The file ended in the middle of something. For a reader of a
        // format, that is a broken file, not the normal end of input.
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return fr.err.?,
        else => |e| return e,
    };

    // Only now, with the whole file checked, do we act on it.
    for (records[0..n]) |*rec| {
        var num: [12]u8 = undefined;
        const score = try std.mem.print(&num, "{d}", .{rec.score});
        try out.print("   id {d:>3}  score {s:>5}  {s}\n", .{ rec.id, score, rec.name() });
    }
}

fn readRecords(r: *Io.Reader, records: []Record) !usize {
    // Check what the file claims to be before trusting anything after it.
    if (!std.mem.eql(u8, try r.takeArray(4), magic)) return FormatError.NotScoresFile;
    if (try r.takeInt(u16, .little) != version) return FormatError.UnsupportedVersion;

    // `count` comes from the file, so it is untrusted like everything else.
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

## The format comes first

Before any code, the snippet writes the format down in a comment.

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

Every byte has a position, a size and a meaning.

All integers are little-endian.

This table is the format. The code only follows it.

A program in another language can read our file if it follows the same table.

## Byte order

A `u32` is four bytes, and they can be stored in two orders.

```
   little  04030201
   big     01020304
```

Little-endian puts the smallest byte first. x86 and ARM machines work this way.

Big-endian puts the largest byte first. Network protocols often use it.

Neither is more correct.

What matters is that the format says which one, and the code names it on every read and write.

That is why `writeInt` and `takeInt` both take the byte order as an argument. There is no default.

## Writing the file

<SnippetSource name="24-files.binary-files" decl="save" />

We write each field on its own.

`writeAll(magic)` writes the four letters `SCOR`.

`writeInt(u16, version, .little)` writes the version as two bytes.

The name is a string of any length, so we write its length first as one byte, then the bytes of the name.

This is called a length prefix.

It is how the reader knows where one name ends and the next record starts.

Here is every byte of the file.

```
   0000  53 43 4f 52 01 00 03 00 00 00 07 00 00 00 b0 04  SCOR............
   0010  00 00 03 61 64 61 2a 00 00 00 f1 ff ff ff 05 6c  ...ada*........l
   0020  69 6e 75 73 2c 01 00 00 00 00 00 00 05 67 72 61  inus,........gra
   0030  63 65                                            ce
   50 bytes
```

We can find each field in it.

`53 43 4f 52` is `SCOR`.

`01 00` is version 1, and `03 00 00 00` is a count of 3, both with the small byte first.

Then the first record: id `07 00 00 00`, score `b0 04 00 00`, which is 0x04b0 or 1200, name length `03`, and `ada`.

Linus's score of -15 is `f1 ff ff ff`, because negative numbers are stored in two's complement.

## Why not write the struct directly

We could copy a `Player` struct's memory to the file in one call.

It would be shorter, and it would be wrong.

A normal Zig struct has no fixed layout. The compiler can reorder the fields and add padding.

Its integers are in the byte order of the machine that wrote them.

So the bytes could change with a new compiler, a different target, or a different build mode.

[A Binary Wire Format](https://www.ziglang.in/learn/how-to/binary-roundtrip/) covers this in more detail. The short rule: write fields one at a time, and name the byte order each time.

## Reading it back

<SnippetSource name="24-files.binary-files" decl="readRecords" />

The reader follows the same table, in the same order.

But it does not trust the file.

Anything could be in it: a different format, a newer version of ours, or a file that was cut short while copying.

So the reader checks before it uses each value.

First the magic. If the first four bytes are not `SCOR`, this is not our file, and we stop.

Then the version. A file from a newer program might have fields we do not know about, so we stop there too.

Then the count.

The count comes from the file, so it is untrusted too.

A broken file could say it holds four billion records. So we compare it with how many we have room for.

The name length gets the same check against the size of `name_buf`.

## Three bad files

```
   photo.png: NotScoresFile
   newer.bin: UnsupportedVersion
   cut.bin: Truncated
```

`photo.png` starts with the PNG signature, so the magic check rejects it.

`newer.bin` is our header with the version changed to 2.

`cut.bin` is our file with the last four bytes removed.

The first two records read fine. The third one ends in the middle of its name.

`take` returns `error.EndOfStream` when there are not enough bytes left.

At the start of a text file, end of stream is normal. It means the input is finished.

In the middle of a record, it means the file is broken. So `printFile` turns `EndOfStream` into our own `error.Truncated`.

## Check everything, then act

<SnippetSource name="24-files.binary-files" decl="printFile" />

`printFile` reads every record into an array first.

It prints only after `readRecords` has checked the whole file.

The first version of this program printed each record as it read it.

For `cut.bin`, it printed two players and then reported the error.

In a real program, acting on each record as it arrives can do damage.

If "print" had been "update the database", half of a broken file would already be saved.

So we read and check everything first, and act only when all of it is valid.

There is one more detail in `readRecords`.

`take(name_len)` returns a slice of the reader's buffer, and the next read can overwrite that buffer.

So we copy the name into `name_buf` with `@memcpy`. The [line reading chapter](https://www.ziglang.in/learn/files/read-lines/#keeping-a-line) has the same rule for lines.
