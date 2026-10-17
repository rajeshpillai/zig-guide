# Reading Line by Line

> A line loop over a file, the three line endings it meets, a line longer than the buffer, and a large file through a small buffer.

Most text files are read one line at a time.

We open the file, wrap it in a reader with a buffer, and ask the reader for the next line until there are none.

The buffer can be small.

The program below reads a file of almost 100 KB through a 256-byte buffer.

It also shows the three things a line loop meets in real files: different line endings, a line longer than the buffer, and a line we want to keep.

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

    // 3. A file much bigger than the buffer that reads it.
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
        // A file written on Windows ends each line with "\r\n". Splitting on
        // '\n' leaves the '\r' on the end of the line, so strip it.
        const line = std.mem.trimEnd(u8, raw, "\r");
        try out.print("     line {d}: \"{f}\" -> \"{s}\"\n", .{ n, std.zig.fmtString(raw), line });
    }
}

fn readSkippingLong(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    // 16 bytes of buffer. The longest line the reader can return is 15
    // characters plus the newline.
    var buf: [16]u8 = undefined;
    var reader = file.reader(io, &buf);
    const r = &reader.interface;

    var n: usize = 1;
    while (true) : (n += 1) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Nothing was consumed. Skip to the end of this line and go on.
                const skipped = try r.discardDelimiterInclusive('\n');
                try out.print("   line {d}: StreamTooLong, skipped {d} bytes\n", .{ n, skipped });
                continue;
            },
            else => |e| return e,
        } orelse break;
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
        // `line` points into `buf`, and the next read overwrites it.
        // Keeping it past this iteration means copying it out.
        @memcpy(last[0..line.len], line);
        last_len = line.len;
    }
    try out.print("   file size {d} bytes, buffer {d} bytes\n", .{ try file.length(io), buf.len });
    try out.print("   {d} lines, {d} bytes, last line \"{s}\"\n", .{ lines, bytes, last[0..last_len] });
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.read-lines`)*

## The loop

<SnippetSource name="24-files.read-lines" decl="printLines" />

`file.reader(io, &buf)` gives us a `File.Reader`.

The generic reading methods are on its `interface` field, which is a `std.Io.Reader`.

`takeDelimiter('\n')` returns the next line without the `'\n'`.

When the file has no more lines, it returns `null`, and the `while` loop ends.

So the whole loop is one `while` with a capture.

[Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/#reading-lines-mind-the-variant) compares `takeDelimiter` with the two methods that have similar names. For a line loop, `takeDelimiter` is the one we want.

## Line endings

The three files hold the same two lines.

Only the bytes at the end of each line are different.

```
   unix.txt
     line 1: "one" -> "one"
     line 2: "two" -> "two"
   no-final.txt
     line 1: "one" -> "one"
     line 2: "two" -> "two"
```

A file that ends with `'\n'` gives two lines, not three.

There is no empty line after the last newline.

A file with no newline at the end still gives its last line.

So both files give the same result, which is what we want.

Windows is different.

A file written on Windows usually ends each line with two bytes, `"\r\n"`.

```
   windows.txt
     line 1: "one\r" -> "one"
     line 2: "two\r" -> "two"
```

We split on `'\n'`, so the `'\r'` stays on the end of the line.

It is easy to miss, because a terminal does not show it.

But `"one\r"` is not equal to `"one"`, and a number parser will reject `"42\r"`.

`std.mem.trimEnd(u8, raw, "\r")` removes it.

On a line without a `'\r'`, it returns the line unchanged. So the same loop reads both kinds of file.

## A line longer than the buffer

The reader can only return a line that fits in its buffer.

In this example the buffer is 16 bytes, and one line is 40 characters long.

```
   line 1: short
   line 2: StreamTooLong, skipped 41 bytes
   line 3: after
```

`takeDelimiter` returns `error.StreamTooLong` for the long line.

It does not return the first 16 bytes and pretend that was the line.

It also does not consume anything. The reader is in the same state as before the call.

So we have a choice.

Here we skip the line with `discardDelimiterInclusive('\n')`.

That reads and throws away bytes up to and including the next newline. It returns 41: forty `x` characters and the newline.

Then the loop continues, and line 3 reads normally.

<SnippetSource name="24-files.read-lines" decl="readSkippingLong" />

Skipping is right for a log file where one bad line should not stop the program.

For input from a user or another program, the error is often the right answer.

The buffer size becomes the longest line we accept, and anything longer is rejected.

If lines really can be any length, use a bigger buffer, or copy each line into an `ArrayList` as it streams.

## A large file through a small buffer

The third file has 10,000 lines.

```
   file size 98894 bytes, buffer 256 bytes
   10000 lines, 98894 bytes, last line "line 10000"
```

The reader never holds more than 256 bytes of it.

When the buffer runs out, the reader moves the unread bytes to the front and reads more from the file.

So the memory this loop uses does not depend on the size of the file.

The same loop reads a 10 GB log with the same 256 bytes.

## Keeping a line

<SnippetSource name="24-files.read-lines" decl="countLines" />

`line` is a slice that points into `buf`.

It is not a copy.

The next call to `takeDelimiter` can refill `buf`, and then the old slice shows different bytes.

So a line is only valid until the next read.

To keep the last line after the loop, we copy it into `last` with `@memcpy`.

To keep every line, we copy each one with `gpa.dupe(u8, line)` and store the copies.

This is the reason a small buffer can read a large file. The reader does not keep old lines, so it only needs room for the current one.

## Writing the test file

`writeNumberedLines` writes the large file through a `File.Writer` with a 4 KB buffer.

`print` writes into the buffer, and the writer sends it to the file each time the buffer fills.

The last `flush()` sends whatever is left.

Without it, the final part of the file is never written.

The next chapter looks at writing more closely.
