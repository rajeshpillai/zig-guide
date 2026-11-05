# Open, Read, Close

> Three ways to read a file, and what each one does when the file is larger than you expect.

Zig has three common ways to read a file:

- `readFileAlloc` reads the full file into new memory.
- `readFile` reads the file into a buffer that you supply.
- `openFile` gives you a handle. Then you decide how to read from the handle.

Each of the three functions needs a size limit. The functions are different in two ways: where the limit comes from, and what occurs when the file is larger than the limit.

The program below uses the three functions on the same 18-byte file.

```zig
const std = @import("std");

const Io = std.Io;

// The playground starts each run in an empty directory. Thus the program
// writes the file before it reads the file. The file is 18 bytes: three
// lines of 6, 5 and 4 characters, and a newline after each line.
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

    // 1. Read the full file into memory from the allocator.
    try out.print("1. readFileAlloc\n", .{});
    const whole = try dir.readFileAlloc(io, "shopping.txt", gpa, .limited(1024));
    defer gpa.free(whole);
    try out.print("   read {d} bytes\n", .{whole.len});

    // The function fails when the file size is equal to the limit, and also
    // when the file size is more than the limit.
    for ([_]usize{ 17, 18, 19 }) |limit| {
        if (dir.readFileAlloc(io, "shopping.txt", gpa, .limited(limit))) |bytes| {
            defer gpa.free(bytes);
            try out.print("   limit {d}: ok, {d} bytes\n", .{ limit, bytes.len });
        } else |err| {
            try out.print("   limit {d}: {t}\n", .{ limit, err });
        }
    }

    // 2. Read into a buffer that you supply. No allocator is necessary. A full
    //    buffer does not tell you if the file is longer than the buffer.
    try out.print("2. readFile\n", .{});
    var small: [8]u8 = undefined;
    const part = try dir.readFile(io, "shopping.txt", &small);
    try out.print("   8-byte buffer: {d} bytes \"{f}\"\n", .{ part.len, std.zig.fmtString(part) });
    var large: [64]u8 = undefined;
    const all = try dir.readFile(io, "shopping.txt", &large);
    try out.print("   64-byte buffer: {d} bytes\n", .{all.len});

    // 3. Open a handle. You must close the handle. Get the length of the
    //    file, then read exactly that number of bytes from offset 0.
    try out.print("3. openFile\n", .{});
    {
        const file = try dir.openFile(io, "shopping.txt", .{});
        defer file.close(io);

        // A file length is a u64. A length in memory is a usize, and a usize
        // is 32 bits on wasm32. If the value is too large, the cast fails.
        // It does not remove the high bits.
        const len = try file.length(io);
        const bytes = try gpa.alloc(u8, std.math.cast(usize, len) orelse return error.FileTooBig);
        defer gpa.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        try out.print("   length {d}, read {d}\n", .{ len, n });
        try out.print("   first line: {s}\n", .{bytes[0..std.mem.findScalar(u8, bytes, '\n').?]});
    }

    // 4. A file that does not exist. The error gives the name of the
    //    problem. Thus the caller can use a default value for this error.
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

## Write the file first

The playground starts each run in an empty directory. In your browser, the directory is in memory. In CI, the directory is a temporary directory on disk.

Thus the program writes `shopping.txt` before it reads the file. One call to `dir.writeFile` creates the file, writes the bytes and closes the file.

The file has three lines: `apples`, `bread` and `milk`. A newline follows each line. The three lines are 6 + 1, 5 + 1 and 4 + 1 bytes, thus the file is 18 bytes.

## Read the full file

`readFileAlloc` opens the file, reads all of the file, closes the file and returns the bytes.

The memory comes from the allocator that you give to the function. Free the memory with the same allocator.

The last argument is a limit, and the limit is necessary. No version of this function reads a quantity of data that has no limit. A file can be of any size. If a program accepts each file without a limit, one day the program will read a very large file into memory.

Be careful with the limit. The output shows the result of three limits:

```
   limit 17: StreamTooLong
   limit 18: StreamTooLong
   limit 19: ok, 18 bytes
```

A limit of 18 fails on an 18-byte file. The function fails when the file size is equal to the limit, and also when the file size is more than the limit.

Thus, if the largest file that you accept is 1 MiB, set the limit to 1 MiB plus one byte. Usually, a programmer selects a round number that is much larger than the expected files, for example `.limited(1 << 20)`.

## Read into a buffer that you supply

`readFile` does not need an allocator. The function reads into the buffer that you give to it. Then it returns the part of the buffer that it filled.

```
   8-byte buffer: 8 bytes "apples\nb"
   64-byte buffer: 18 bytes
```

The 8-byte buffer has space for 8 bytes. Thus the function read 8 bytes and stopped. The function did not return an error.

When the result fills the full buffer, the result does not tell you which of these two conditions is true:

- The file is exactly 8 bytes long.
- The file is longer than 8 bytes, and the program did not read the other bytes.

If you must know the difference, make the buffer one byte larger than the largest file that you accept. Then a full buffer always means that the file is too large.

The limit in `readFileAlloc` uses the same rule. This rule is the reason that a limit equal to the file size fails.

## Open a handle

`openFile` returns a `File`. You must close the file. Thus the next line is `defer file.close(io)`.

The `defer` statement runs when the block ends. It runs on all paths, and an early `return` from a `try` is one of these paths.

When the handle is open, the program gets the length of the file. Then it allocates memory of exactly that length.

```
   length 18, read 18
   first line: apples
```

Between these two steps, the program must change the type of the length:

- `file.length` returns a `u64`, because a file on disk can be larger than 4 GiB.
- `gpa.alloc` takes a `usize`. A `usize` has the same size as an address.

On a 64-bit computer, the two types have the same width. This program also runs as `wasm32`, where `usize` is 32 bits. Thus the compiler does not let you use a `u64` as a `usize`.

`std.math.cast(usize, len)` returns `null` when the value is too large for a `usize`. The program changes this `null` into `error.FileTooBig`.

Then the program reads the file with `readPositionalAll`. This function reads from a given offset until the buffer is full or the file ends. It returns the number of bytes that it read. In this example, the number is 18, which is equal to the length.

The two numbers can be different. Another program can make the file shorter after the call to `length` and before the read. Thus the program uses the count that the read returns. It does not use the length from the earlier call.

## A file that does not exist

When you open a file that does not exist, the result is `error.FileNotFound`.

```
   settings.txt: FileNotFound, using defaults
```

The program uses a `switch` on the error. For `FileNotFound`, the program has a correct action: it uses the default settings.

For each other error, the program returns the error to the caller with `return err`. This code cannot repair a permission problem or a full disk. Thus the code must not hide these errors.

Do not write `catch` without an error name, and do not use one action for all errors. If you do, a settings file that the program cannot read looks the same as a settings file that does not exist. Then no person gets a report about the problem.

## Select a function

- For a small file that you read one time, use `readFileAlloc`. It needs the least code.
- For a record of fixed size, or for a file that you know is small, use `readFile`. It does not need an allocator.
- For all other files, open a handle. With a handle, you can read the file in parts, move to a different position, and read a file that is larger than memory.

The next chapter uses a handle to read a file one line at a time.

## If you used an older version of Zig

Before version 0.16, these functions were on `std.fs.Dir`, and they did not have an `io` argument.

Now the functions are on `std.Io.Dir`. The `io` argument is the first argument after the directory.

[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) gives a list of the functions that moved.
