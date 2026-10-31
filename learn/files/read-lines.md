# Read Line by Line

> A line loop over a file, three types of line ending, a line longer than the buffer, and a large file through a small buffer.

Usually, a program reads a text file one line at a time. To read the lines of a file, do these steps:

1. Open the file.
2. Put a reader with a buffer around the file.
3. Get the next line from the reader. Do this again until no lines remain.

The buffer can be small. The program below reads a file of almost 100 KB through a 256-byte buffer.

The program also shows three conditions that a line loop finds in real files:

- Different line endings.
- A line that is longer than the buffer.
- A line that the program must keep.

```zig
const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Three files with the same two lines and different endings.
    try out.print("1. line endings\n", .{});
    const endings = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "unix.txt", .data = "one\ntwo\n" },
        .{ .name = "no-final.txt", .data = "one\ntwo" },
        .{ .name = "windows.txt", .data = "one\r\ntwo\r\n" },
    };
    for (endings) |e| {
        try dir.writeFile(io, .{ .sub_path = e.name, .data = e.data });
        try out.print("   {s}\n", .{e.name});
        try printLines(io, dir, e.name, out);
    }

    // 2. A line longer than the reader's buffer.
    try out.print("2. a long line\n", .{});
    try dir.writeFile(io, .{
        .sub_path = "long.txt",
        .data = "short\n" ++ @as([40]u8, @splat('x')) ++ "\nafter\n",
    });
    try readSkippingLong(io, dir, "long.txt", out);

    // 3. A file that is much larger than the buffer that reads it.
    try out.print("3. a large file\n", .{});
    try writeNumberedLines(io, dir, "big.txt", 10_000);
    try countLines(io, dir, "big.txt", out);

    for ([_][]const u8{ "unix.txt", "no-final.txt", "windows.txt", "long.txt", "big.txt" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn printLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);

    var n: usize = 1;
    while (try reader.interface.takeDelimiter('\n')) |raw| : (n += 1) {
        // A file from Windows has "\r\n" at the end of each line. A split at
        // '\n' keeps the '\r' at the end of the line. Thus remove the '\r'.
        const line = std.mem.trimEnd(u8, raw, "\r");
        try out.print("     line {d}: \"{f}\" -> \"{s}\"\n", .{ n, std.zig.fmtString(raw), line });
    }
}

fn readSkippingLong(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    // The buffer is 16 bytes. The longest line that the reader can return
    // is 15 characters and the newline.
    var buf: [16]u8 = undefined;
    var reader = file.reader(io, &buf);
    const r = &reader.interface;

    var n: usize = 1;
    while (true) : (n += 1) {
        // The parentheses are necessary: `catch` handles the error, then
        // `orelse` handles the end of the file.
        const line = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // The reader consumed no bytes. Skip to the end of this line,
                // then continue.
                const skipped = try r.discardDelimiterInclusive('\n');
                try out.print("   line {d}: StreamTooLong, skipped {d} bytes\n", .{ n, skipped });
                continue;
            },
            else => |e| return e,
        }) orelse break;
        try out.print("   line {d}: {s}\n", .{ n, line });
    }
}

fn writeNumberedLines(io: Io, dir: Io.Dir, name: []const u8, count: usize) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    for (1..count + 1) |i| try writer.interface.print("line {d}\n", .{i});
    try writer.interface.flush();
}

fn countLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var reader = file.reader(io, &buf);

    var lines: usize = 0;
    var bytes: usize = 0;
    var last: [16]u8 = undefined;
    var last_len: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        lines += 1;
        bytes += line.len + 1;
        // `line` points into `buf`, and the next read writes over `buf`.
        // To keep the line after this iteration, copy the line.
        @memcpy(last[0..line.len], line);
        last_len = line.len;
    }
    try out.print("   file size {d} bytes, buffer {d} bytes\n", .{ try file.length(io), buf.len });
    try out.print("   {d} lines, {d} bytes, last line \"{s}\"\n", .{ lines, bytes, last[0..last_len] });
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.read-lines`)*

## The loop

```zig
fn printLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);

    var n: usize = 1;
    while (try reader.interface.takeDelimiter('\n')) |raw| : (n += 1) {
        // A file from Windows has "\r\n" at the end of each line. A split at
        // '\n' keeps the '\r' at the end of the line. Thus remove the '\r'.
        const line = std.mem.trimEnd(u8, raw, "\r");
        try out.print("     line {d}: \"{f}\" -> \"{s}\"\n", .{ n, std.zig.fmtString(raw), line });
    }
}
```

*Quoted from the source: `printLines` from `snippets/24-files/read-lines.zig`.*

`file.reader(io, &buf)` gives you a `File.Reader`. The general read methods are on its `interface` field, which is a `std.Io.Reader`.

`takeDelimiter('\n')` returns the next line without the `'\n'`. When the file has no more lines, the method returns `null`, and the `while` loop stops. Thus the full loop is one `while` with a capture.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/#read-lines-select-the-correct-variant) compares `takeDelimiter` with the two methods that have similar names. For a line loop, use `takeDelimiter`.

## Line endings

The three files have the same two lines. Only the bytes at the end of each line are different.

```
   unix.txt
     line 1: "one" -> "one"
     line 2: "two" -> "two"
   no-final.txt
     line 1: "one" -> "one"
     line 2: "two" -> "two"
```

A file that ends with `'\n'` gives two lines, not three. No empty line comes after the last newline.

A file without a newline at the end also gives its last line. Thus the two files give the same result, and that result is correct.

Windows is different. Usually, a file from Windows has two bytes, `"\r\n"`, at the end of each line.

```
   windows.txt
     line 1: "one\r" -> "one"
     line 2: "two\r" -> "two"
```

The program splits each line at `'\n'`. Thus the `'\r'` stays at the end of the line. You can easily miss the `'\r'`, because a terminal does not show it. But `"one\r"` is not equal to `"one"`, and a number parser rejects `"42\r"`.

`std.mem.trimEnd(u8, raw, "\r")` removes the `'\r'`. On a line without a `'\r'`, the function returns the line with no change. Thus the same loop reads the two types of file.

## A line longer than the buffer

The reader can return only a line that fits in its buffer. In this example, the buffer is 16 bytes, and one line is 40 characters long.

```
   line 1: short
   line 2: StreamTooLong, skipped 41 bytes
   line 3: after
```

For the long line, `takeDelimiter` returns `error.StreamTooLong`. The method does not return the first 16 bytes as if they are the full line. Also, the method does not consume bytes. The reader has the same state as before the call.

Thus you must make a decision. In this example, the program skips the line with `discardDelimiterInclusive('\n')`. That method reads bytes up to the next newline, and the newline too, and discards them. It returns 41: forty `x` characters and the newline.

Then the loop continues, and the reader reads line 3 correctly.

```zig
fn readSkippingLong(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    // The buffer is 16 bytes. The longest line that the reader can return
    // is 15 characters and the newline.
    var buf: [16]u8 = undefined;
    var reader = file.reader(io, &buf);
    const r = &reader.interface;

    var n: usize = 1;
    while (true) : (n += 1) {
        // The parentheses are necessary: `catch` handles the error, then
        // `orelse` handles the end of the file.
        const line = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // The reader consumed no bytes. Skip to the end of this line,
                // then continue.
                const skipped = try r.discardDelimiterInclusive('\n');
                try out.print("   line {d}: StreamTooLong, skipped {d} bytes\n", .{ n, skipped });
                continue;
            },
            else => |e| return e,
        }) orelse break;
        try out.print("   line {d}: {s}\n", .{ n, line });
    }
}
```

*Quoted from the source: `readSkippingLong` from `snippets/24-files/read-lines.zig`.*

The result of `takeDelimiter` can be an error or `null`. `catch` handles the error, and `orelse break` handles `null`, the end of the file. Put parentheses around the `catch` part, as the code above does.

Zig 0.17 accepted the line without the parentheses and read it as `(… catch …) orelse break`. Zig master does not accept the two operators together without parentheses. The error is `ambiguous operator precedence with operators ... catch ... orelse ...`. The parentheses make the old meaning explicit, and the program does not change.

Skip the line for a log file, where one bad line must not stop the program. For input from a user or from a different program, the error is frequently the correct result.

In that case, the buffer size is the longest line that you accept, and the reader rejects each longer line. If a line can truly have any length, use a larger buffer. Alternatively, copy each part of the line into an `ArrayList` when the reader reads it.

## A large file through a small buffer

The third file has 10,000 lines.

```
   file size 98894 bytes, buffer 256 bytes
   10000 lines, 98894 bytes, last line "line 10000"
```

The reader never holds more than 256 bytes of the file. When the buffer has no more bytes, the reader moves the bytes that it did not read to the start of the buffer. Then it reads more bytes from the file.

Thus the memory for this loop does not change with the size of the file. The same loop reads a 10 GB log with the same 256 bytes.

## Keep a line

```zig
fn countLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var reader = file.reader(io, &buf);

    var lines: usize = 0;
    var bytes: usize = 0;
    var last: [16]u8 = undefined;
    var last_len: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        lines += 1;
        bytes += line.len + 1;
        // `line` points into `buf`, and the next read writes over `buf`.
        // To keep the line after this iteration, copy the line.
        @memcpy(last[0..line.len], line);
        last_len = line.len;
    }
    try out.print("   file size {d} bytes, buffer {d} bytes\n", .{ try file.length(io), buf.len });
    try out.print("   {d} lines, {d} bytes, last line \"{s}\"\n", .{ lines, bytes, last[0..last_len] });
}
```

*Quoted from the source: `countLines` from `snippets/24-files/read-lines.zig`.*

`line` is a slice that points into `buf`. The slice is not a copy. The next call to `takeDelimiter` can put new bytes into `buf`, and then the old slice shows different bytes. Thus a line is valid only until the next read.

To keep the last line after the loop, the program copies the line into `last` with `@memcpy`. To keep all lines, copy each line with `gpa.dupe(u8, line)` and store the copies.

This rule is the reason that a small buffer can read a large file. The reader does not keep old lines. Thus the reader needs space only for the current line.

## Write the test file

`writeNumberedLines` writes the large file through a `File.Writer` with a 4 KB buffer. `print` writes into the buffer. Each time the buffer becomes full, the writer sends the buffer to the file.

The last call to `flush()` sends the bytes that remain. Without that call, the program never writes the last part of the file.

The next chapter gives more information about how to write a file.
