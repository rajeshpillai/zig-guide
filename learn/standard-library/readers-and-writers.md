# Readers and Writers

> The buffered Reader and Writer interfaces introduced in Zig 0.15.

In Zig, code reads bytes through `std.Io.Reader` and writes bytes through `std.Io.Writer`. Thus one parser or formatter works with a file, a socket or a fixed buffer.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "iterate lines with takeDelimiter" {
    var reader: std.Io.Reader = .fixed("line one\nline two\n");

    // `takeDelimiter` consumes the delimiter and returns null at the end.
    // A line loop needs this behaviour.
    var count: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        count += 1;
        try expect(line.len == 8);
    }
    try expect(count == 2);
}

test "the Exclusive variant leaves the delimiter behind" {
    var reader: std.Io.Reader = .fixed("line one\nline two\n");

    const first = try reader.takeDelimiterExclusive('\n');
    try expect(std.mem.eql(u8, first, "line one"));

    // The first call did NOT consume the '\n'. Thus the next call sees the
    // '\n' immediately and returns an empty slice. To loop over lines, use
    // `takeDelimiter`. Or call `toss(1)` to skip the delimiter.
    const second = try reader.takeDelimiterExclusive('\n');
    try expect(second.len == 0);

    reader.toss(1);
    const third = try reader.takeDelimiterExclusive('\n');
    try expect(std.mem.eql(u8, third, "line two"));
}

test "take a fixed number of bytes" {
    var reader: std.Io.Reader = .fixed("abcdef");
    const chunk = try reader.take(3);
    try expect(std.mem.eql(u8, chunk, "abc"));
}

test "write into a caller-owned buffer" {
    var buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeAll("hello");
    try writer.print(" {d}", .{42});

    try expect(std.mem.eql(u8, writer.buffered(), "hello 42"));
}

test "allocating writer grows as needed" {
    const gpa = std.testing.allocator;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    for (0..5) |i| try writer.writer.print("{d},", .{i});
    try expect(std.mem.eql(u8, writer.written(), "0,1,2,3,4,"));
}

test "a fixed writer reports when it runs out" {
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.WriteFailed, writer.writeAll("too long"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.readers-and-writers`)*

Zig 0.15 replaced the old generic `Reader` and `Writer` with the non-generic `std.Io.Reader` and `std.Io.Writer`. Two of the changes are important in daily work:

1. **The buffer belongs to the interface**, not to the implementation. You supply the buffer. Thus there is no hidden allocation, and you control the size.
2. **Writers have a buffer**, thus you must call `flush`. A common mistake with the new API is to forget the flush.

The important word in the first sentence is "non-generic". The old `Writer` was a type parameter. Thus each function that took a writer was generic, and the compiler compiled it again for each writer type. A struct that stored a writer also had to be generic.

`std.Io.Writer` is a concrete type that holds a pointer and a vtable. Thus a function takes a `*std.Io.Writer` and needs nothing more. Compile times become shorter, error messages become shorter, and you can put a writer in a field.

## Create them

```zig
var reader: std.Io.Reader = .fixed("some bytes");
var writer: std.Io.Writer = .fixed(&buf);

var growable: std.Io.Writer.Allocating = .init(gpa);
```

For files, `file.writerStreaming(io, &buf)` gives you a `File.Writer`. The `.interface` field of the `File.Writer` is the `std.Io.Writer` to use.

Learn to recognise that `.interface` field, because it is a pattern. The concrete type holds the state that a file writer needs. It also contains the generic interface as a field. Thus you give `&file_writer.interface` to each function that takes a writer.

Sometimes the compiler gives an error about a `File.Writer` where it expects a `*std.Io.Writer`. Almost always, the cause is that you forgot `.interface`.

## Flush, and where to put the flush

```zig
var buf: [4096]u8 = undefined;
var fw = std.Io.File.stdout().writerStreaming(io, &buf);
defer fw.interface.flush() catch {};

try fw.interface.print("{d}\n", .{42});
```

No data goes to the file until the buffer is full or you flush. A program that prints and then exits without a flush prints nothing. The first time that you see this result, it can confuse you. For this reason, put the `defer` directly below the line that creates the writer.

You select the buffer size, and the size is important:

- A buffer of one byte causes a syscall for each write.
- Four kilobytes is a page, and it is a sensible default.
- A larger buffer helps for bulk output. It gives no benefit to a program that prints six lines.

## Read lines: select the correct variant

It is easy to confuse these three methods. An earlier version of this page had this error:

| Method | Consumes delimiter | At end of stream |
| --- | --- | --- |
| `takeDelimiter` | yes | returns `null` |
| `takeDelimiterExclusive` | **no** | error |
| `takeDelimiterInclusive` | yes, and includes it | error |

Thus, when you call `takeDelimiterExclusive` two times on `"a\nb\n"`, it returns `"a"` and then an **empty slice**. The reason is that the `\n` is still in the reader. For a line loop, use this code:

```zig
while (try reader.takeDelimiter('\n')) |line| { ... }
```

If you use the exclusive form, call `toss(n)` to skip the bytes yourself.

The slice that a `take` returns points into the buffer of the reader. The slice is valid until the next read. To keep a line, copy it. `ArrayList.items` has the same rule: the slice is a borrowed view. This rule lets you read a large file with a small buffer.

## When the buffer is full

When the buffer of a `.fixed` writer is full, the writer fails with `error.WriteFailed`. It does not silently remove the extra bytes.

A reader has the same rule. When a line is longer than the buffer of the reader, the result is `error.StreamTooLong`, not a partial line. The interface does not give you data that looks complete but is not complete.

Sometimes the input comes from a source that you do not trust, and a line can have any length. In that case, the error is your length limit. Usually it is correct to treat the error as a protocol violation.

## Why one interface

With one interface, the parts work together. A parser that uses `*std.Io.Reader` gets its tests with `.fixed("literal input")`. Then the same parser, with no change, reads from a socket in production. A formatter that uses `*std.Io.Writer` writes to a file, a buffer, or a hash.

For this reason, the [networking](https://www.ziglang.in/learn/networking/) chapters can run in a browser. The protocol code takes bytes and returns bytes. Only the chapters about sockets need a socket.
