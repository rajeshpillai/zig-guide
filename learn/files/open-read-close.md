# Open, Read, Close

> Three ways to read a file, and what each one does when the file is bigger than you planned for.

Zig gives us three common ways to read a file.

`readFileAlloc` reads the whole file into new memory.

`readFile` reads into a buffer we already have.

`openFile` gives us a handle, and we decide how to read from it.

All three need a size limit of some kind.

The difference is where that limit comes from, and what happens when the file is bigger.

The program below uses all three on the same 18-byte file.

```zig
const std = @import("std");

const Io = std.Io;

// The playground starts every run in an empty directory, so the program
// writes the file it is about to read. 18 bytes: three lines of 5, 6 and 5
// characters, each followed by a newline.
const shopping = "apples\nbread\nmilk\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "shopping.txt", .data = shopping });

    // 1. The whole file, into memory the allocator owns.
    try out.print("1. readFileAlloc\n", .{});
    const whole = try dir.readFileAlloc(io, "shopping.txt", gpa, .limited(1024));
    defer gpa.free(whole);
    try out.print("   read {d} bytes\n", .{whole.len});

    // The limit counts the file size too. Reaching it is an error, not only
    // going past it, so a limit equal to the size fails.
    for ([_]usize{ 17, 18, 19 }) |limit| {
        if (dir.readFileAlloc(io, "shopping.txt", gpa, .limited(limit))) |bytes| {
            defer gpa.free(bytes);
            try out.print("   limit {d}: ok, {d} bytes\n", .{ limit, bytes.len });
        } else |err| {
            try out.print("   limit {d}: {t}\n", .{ limit, err });
        }
    }

    // 2. Into a buffer we already have. No allocator, but a full buffer is
    //    ambiguous: the file fitted exactly, or there was more.
    try out.print("2. readFile\n", .{});
    var small: [8]u8 = undefined;
    const part = try dir.readFile(io, "shopping.txt", &small);
    try out.print("   8-byte buffer: {d} bytes \"{f}\"\n", .{ part.len, std.zig.fmtString(part) });
    var large: [64]u8 = undefined;
    const all = try dir.readFile(io, "shopping.txt", &large);
    try out.print("   64-byte buffer: {d} bytes\n", .{all.len});

    // 3. A handle we open and close ourselves. Ask the file its length,
    //    then read exactly that many bytes from offset 0.
    try out.print("3. openFile\n", .{});
    {
        const file = try dir.openFile(io, "shopping.txt", .{});
        defer file.close(io);

        // A file length is a u64. A length in memory is a usize, which is
        // 32 bits on wasm32. The cast fails rather than truncating.
        const len = try file.length(io);
        const bytes = try gpa.alloc(u8, std.math.cast(usize, len) orelse return error.FileTooBig);
        defer gpa.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        try out.print("   length {d}, read {d}\n", .{ len, n });
        try out.print("   first line: {s}\n", .{bytes[0..std.mem.findScalar(u8, bytes, '\n').?]});
    }

    // 4. A file that is not there. The error names the problem, so the
    //    caller can decide it is not a problem at all.
    try out.print("4. missing file\n", .{});
    if (dir.openFile(io, "settings.txt", .{})) |file| {
        file.close(io);
    } else |err| switch (err) {
        error.FileNotFound => try out.print("   settings.txt: FileNotFound, using defaults\n", .{}),
        else => return err,
    }

    try dir.deleteFile(io, "shopping.txt");
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.open-read-close`)*

## The file comes first

The playground gives every run an empty directory.

In your browser that directory lives in memory. In CI it is a temp directory on disk.

So the program writes `shopping.txt` before it reads it.

`dir.writeFile` creates the file, writes the bytes and closes it in one call.

The file holds three lines: `apples`, `bread` and `milk`, each followed by a newline.

That is 6 + 1, 5 + 1 and 4 + 1 bytes, so 18 in total.

## Reading the whole file

`readFileAlloc` opens the file, reads all of it, closes it and returns the bytes.

The memory comes from the allocator we pass in, so we free it with the same allocator.

The last argument is a limit, and it is required.

There is no version of this call that reads an unlimited amount.

A file can be any size, and a program that trusts every file to be small will one day read a very large one into memory.

The limit has one detail that is easy to get wrong.

```
   limit 17: StreamTooLong
   limit 18: StreamTooLong
   limit 19: ok, 18 bytes
```

A limit of 18 fails on an 18-byte file.

The rule is "reached or exceeded", not only "exceeded".

So if we know the largest file we accept is 1 MiB, the limit is 1 MiB plus one byte.

In practice we pick a round number well above any file we expect, like `.limited(1 << 20)`.

## Reading into a buffer we already have

`readFile` needs no allocator.

It reads into the buffer we pass in, and returns the part of the buffer it filled.

```
   8-byte buffer: 8 bytes "apples\nb"
   64-byte buffer: 18 bytes
```

With 8 bytes of room, it read 8 bytes and stopped.

It did not return an error.

So when the result fills the whole buffer, we cannot tell which case we are in.

Maybe the file was exactly 8 bytes long.

Maybe it was longer, and the rest is still on disk.

If that difference matters, we make the buffer one byte bigger than the largest file we accept.

Then a full buffer always means "too big".

The limit in `readFileAlloc` works the same way, which is why it fails at the file size.

## Opening a handle

`openFile` returns a `File`.

We close it ourselves, so the next line is `defer file.close(io)`.

The `defer` runs when the block ends, on every path, including an early `return` from a `try`.

With the handle open, we ask for the length and allocate exactly that much.

```
   length 18, read 18
   first line: apples
```

There is a small type conversion in the middle of this.

`file.length` returns a `u64`, because a file on disk can be larger than 4 GiB.

`gpa.alloc` takes a `usize`, which is the size of an address.

On a 64-bit machine they are the same width.

This program also runs as `wasm32`, where `usize` is 32 bits.

So the compiler refuses to pass one as the other.

`std.math.cast(usize, len)` returns `null` when the value does not fit. We turn that into `error.FileTooBig`.

Then we read with `readPositionalAll`, which reads from a given offset until the buffer is full or the file ends.

It returns how many bytes it read. Here that is 18, the same as the length.

Those two numbers can differ.

Another program can make the file shorter between our `length` call and our read.

So we use the count the read returns, not the length we asked for earlier.

## A file that is not there

Opening a file that does not exist returns `error.FileNotFound`.

```
   settings.txt: FileNotFound, using defaults
```

We handle it with a `switch` on the error.

`FileNotFound` has a sensible answer here: use the default settings.

Every other error goes back to the caller with `return err`.

A permission problem or a full disk is not something this code knows how to fix, so it should not hide it.

A common mistake is to write `catch` with no error name, and treat every failure as "file missing".

Then a settings file the program cannot read looks exactly like no settings file, and nobody is told.

## Which one to use

For a small file we read once, `readFileAlloc` is the shortest code.

For a fixed-size record, or a file we know is small, `readFile` avoids the allocator.

For anything else, we open a handle.

A handle lets us read in pieces, seek, and read a file larger than memory.

The next chapter reads a file one line at a time through a handle.

## If you have used older Zig

Before 0.16 these functions lived on `std.fs.Dir` and took no `io` argument.

Now they live on `std.Io.Dir`, and `io` is the first argument after the directory.

[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) lists what moved.
