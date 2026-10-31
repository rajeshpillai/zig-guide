# Write Text Files

> Truncate or keep, create only if new, append, the flush that the program forgot, and how to replace a file in one step.

To write a file looks simple. You create the file, write some bytes and close the file. But some options change the bytes on disk, and the default values do not always do what you expect.

The program below writes six small files. Then it shows the contents of each file.

```zig
const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. By default, createFile truncates. With `.truncate = false`, the new
    //    bytes replace the start of the old bytes, and the other bytes stay.
    try out.print("1. truncate\n", .{});
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{}, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = true: ", out);
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{ .truncate = false }, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = false:", out);

    // 2. Create a file only if the file does not exist.
    try out.print("2. exclusive\n", .{});
    for (0..2) |attempt| {
        if (dir.createFile(io, "id.txt", .{ .exclusive = true })) |file| {
            file.close(io);
            try out.print("   attempt {d}: created\n", .{attempt + 1});
        } else |err| {
            try out.print("   attempt {d}: {t}\n", .{ attempt + 1, err });
        }
    }

    // 3. Append: open the file, then start the writer at the end. The mode
    //    is read_write because, on WASI, a request for the length needs read
    //    access. On Linux or macOS, write_only is sufficient.
    try out.print("3. append\n", .{});
    try writeText(io, dir, "log.txt", .{}, "started\n");
    for ([_][]const u8{ "loaded 3 items\n", "stopped\n" }) |line| {
        const file = try dir.openFile(io, "log.txt", .{ .mode = .read_write });
        defer file.close(io);
        var buf: [64]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.seekTo(try file.length(io));
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }
    try show(io, gpa, dir, "log.txt", "", out);

    // 4. The bytes stay in the buffer of the writer until a flush.
    try out.print("4. flush\n", .{});
    {
        const file = try dir.createFile(io, "lost.txt", .{});
        var buf: [64]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll("this line never reaches the file\n");
        try out.print("   buffered {d} bytes, file length {d}\n", .{ writer.interface.buffered().len, try file.length(io) });
        file.close(io); // close without flush
    }
    try out.print("   after close: {d} bytes on disk\n", .{(try dir.statFile(io, "lost.txt", .{})).size});

    // 5. Replace a file in one step. The new contents go to a temporary
    //    file in the same directory. A rename then moves that file into place.
    try out.print("5. atomic replace\n", .{});
    try writeText(io, dir, "config.txt", .{}, "port = 8080\n");
    {
        var atomic = try dir.createFileAtomic(io, "config.txt", .{ .replace = true });
        defer atomic.deinit(io);

        var buf: [64]u8 = undefined;
        var writer = atomic.file.writer(io, &buf);
        try writer.interface.writeAll("port = 9090\n");
        try writer.interface.flush();

        try show(io, gpa, dir, "config.txt", "   while writing:", out);
        try atomic.replace(io);
    }
    try show(io, gpa, dir, "config.txt", "   after replace:", out);

    // The same steps, but the program fails before `replace`. `deinit`
    // deletes the temporary file, and the old contents do not change.
    {
        var atomic = try dir.createFileAtomic(io, "config.txt", .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, "port = ");
        // ...an error occurs here, and the block returns before replace.
    }
    try show(io, gpa, dir, "config.txt", "   after a failed write:", out);
    try out.print("   files in the directory: {d}\n", .{try countEntries(io, dir)});

    for ([_][]const u8{ "note.txt", "id.txt", "log.txt", "lost.txt", "config.txt" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn writeText(io: Io, dir: Io.Dir, name: []const u8, options: Io.Dir.CreateFileOptions, text: []const u8) !void {
    const file = try dir.createFile(io, name, options);
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn show(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, name: []const u8, label: []const u8, out: *Io.Writer) !void {
    const text = try dir.readFileAlloc(io, name, gpa, .limited(4096));
    defer gpa.free(text);
    if (label.len == 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| try out.print("   {s}\n", .{line});
    } else {
        try out.print("{s} \"{f}\"\n", .{ label, std.zig.fmtString(text) });
    }
}

fn countEntries(io: Io, dir: Io.Dir) !usize {
    var d = try dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.write-text`)*

## The helper

```zig
fn writeText(io: Io, dir: Io.Dir, name: []const u8, options: Io.Dir.CreateFileOptions, text: []const u8) !void {
    const file = try dir.createFile(io, name, options);
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}
```

*Quoted from the source: `writeText` from `snippets/24-files/write-text.zig`.*

Each write in this chapter uses the same three steps:

1. `createFile` opens the file for write operations. If the file does not exist, `createFile` creates the file.
2. `file.writer(io, &buf)` gives you a `File.Writer` with a 64-byte buffer.
3. The program writes through `writer.interface`. Then it calls `flush()`, which sends the bytes that remain in the buffer to the file.

The `options` argument controls what occurs when the file exists already.

## Truncate

By default, `createFile` truncates the file. The function removes the old contents before the program writes.

```
   truncate = true:  "v2\n"
   truncate = false: "v2\nst version\n"
```

With `.truncate = false`, the file keeps its old bytes. The writer starts at offset 0. Thus `"v2\n"` replaces the first three bytes of `"first version\n"`. The other bytes, `"st version\n"`, stay in the file.

For a text file, you almost never want this result. But it is useful for a file of records of fixed size, where you change one record and keep the other records. The [Random Access](https://www.ziglang.in/learn/files/random-access/) chapter shows this.

## Create only if new

`.exclusive = true` creates the file. If the file exists already, the call fails.

```
   attempt 1: created
   attempt 2: PathAlreadyExists
```

The check and the create occur in one step. This is important when two programs run at the same time.

If you check first with `statFile` and create the file after the check, the other program can create the file between your two calls. With `.exclusive = true`, only one of the two programs succeeds.

## Append

`createFile` does not have an append option, and `openFile` does not have one. Thus the program opens the file and starts the writer at the end.

```
   started
   loaded 3 items
   stopped
```

`writer.seekTo(try file.length(io))` moves the writer to the current end of the file. Then each new line goes after the old lines.

The program opens the file with `.mode = .read_write`, not `.write_only`. The reason is WASI, where this program runs. On WASI, Zig asks for the right to read the size of a file only when it opens the file for read operations. Thus, on WASI, `file.length` on a write-only file fails with `AccessDenied`. On Linux and macOS, `.write_only` works.

The append has one more limit. The seek to the end and the write are two separate steps. If two programs append to the same file at the same time, the two programs can seek to the same end. Then each program writes over the bytes of the other program.

[Two Writers, One File](https://www.ziglang.in/learn/storage/filelock/) shows this problem, and the lock that prevents it.

## The forgotten flush

This part of the program writes a line. Then it closes the file, but it does not call `flush()`.

```
   buffered 33 bytes, file length 0
   after close: 0 bytes on disk
```

`writeAll` copied the 33 bytes into the buffer of the writer. No bytes went to the file, because the buffer was not full.

`close` closes the file, but it does not know about the buffer. Thus the bytes are lost, and you get no error.

To correct the problem, call `flush()` before you close the file. In a function that returns early on errors, put the call immediately after the last write. Then `try` reports a flush that fails.

## Replace a file in one step

For example, a program writes a new `config.txt` while a different program reads the file. If the reader opens the file in the middle of the write, the reader gets half of the configuration. If the writer stops unexpectedly in the middle of the write, the file stays half written.

`createFileAtomic` prevents the two problems. The function writes to a new temporary file in the same directory. When you call `replace`, the function renames the temporary file to `config.txt`.

On Linux and macOS, a rename in one directory occurs in one step. A reader sees the old file or the new file, but never a mix of the two files.

```
   while writing: "port = 8080\n"
   after replace: "port = 9090\n"
```

During the write, `config.txt` still had the old contents.

The second block fails intentionally. It writes half a line and returns before `replace`.

```
   after a failed write: "port = 9090\n"
   files in the directory: 5
```

`deinit` runs from the `defer` statement and deletes the temporary file. The old contents do not change, and no temporary file stays in the directory.

Always call `deinit`, also after a `replace` that succeeds. In the two conditions, the call to `deinit` is safe.

The option `.replace = true` must agree with the call at the end:

- `replace` writes over a file that exists.
- `link` is the other choice. If the file exists already, `link` fails with `PathAlreadyExists`, the same as `.exclusive = true`.

## Select a function

- For a new file that you write one time, use `createFile` with the default options.
- For a log, open the file and seek to the end.
- For a file that a different program reads, or a file that must never be half written, use `createFileAtomic`.

In all of these conditions, flush before you close the file.
