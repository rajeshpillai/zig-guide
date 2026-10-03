# Writing Text Files

> Truncate or keep, create only if new, append, the flush that was forgotten, and replacing a file in one step.

Writing a file looks simple.

We create it, write some bytes and close it.

But a few options change what ends up on disk, and the defaults are not always what we expect.

The program below writes six small files and shows what each one holds afterwards.

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

    // 1. createFile truncates by default. With `.truncate = false`, the new
    //    bytes are written over the start of the old ones and the rest stays.
    try out.print("1. truncate\n", .{});
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{}, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = true: ", out);
    try writeText(io, dir, "note.txt", .{}, "first version\n");
    try writeText(io, dir, "note.txt", .{ .truncate = false }, "v2\n");
    try show(io, gpa, dir, "note.txt", "   truncate = false:", out);

    // 2. Create a file only if it does not exist yet.
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
    //    is read_write because asking for the length needs read access on
    //    WASI; on Linux or macOS write_only would do.
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

    // 4. The bytes wait in the writer's buffer until a flush.
    try out.print("4. flush\n", .{});
    {
        const file = try dir.createFile(io, "lost.txt", .{});
        var buf: [64]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll("this line never reaches the file\n");
        try out.print("   buffered {d} bytes, file length {d}\n", .{ writer.interface.buffered().len, try file.length(io) });
        file.close(io); // closed without flush
    }
    try out.print("   after close: {d} bytes on disk\n", .{(try dir.statFile(io, "lost.txt", .{})).size});

    // 5. Replace a file in one step. The new content goes to a temporary
    //    file next to it, and a rename puts it in place.
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

    // The same, but the program fails before `replace`. `deinit` deletes
    // the temporary file and the old content is untouched.
    {
        var atomic = try dir.createFileAtomic(io, "config.txt", .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, "port = ");
        // ...an error happens here, and we return before replace.
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

<SnippetSource name="24-files.write-text" decl="writeText" />

Every write in this chapter goes through the same three steps.

`createFile` opens the file for writing, and creates it if it is not there.

`file.writer(io, &buf)` gives us a `File.Writer` with a 64-byte buffer.

We write through `writer.interface`, then call `flush()` to send what is left in the buffer to the file.

The `options` argument decides what happens when the file already exists.

## Truncate

By default `createFile` truncates. The old content is removed before we write.

```
   truncate = true:  "v2\n"
   truncate = false: "v2\nst version\n"
```

With `.truncate = false`, the file keeps its old bytes.

The writer starts at offset 0, so `"v2\n"` is written over the first three bytes of `"first version\n"`.

The remaining bytes, `"st version\n"`, are still there.

This is almost never what we want for a text file.

It is useful for a file of fixed-size records, where we change one record and keep the others. The [Random Access](https://www.ziglang.in/learn/files/random-access/) chapter does that.

## Create only if new

`.exclusive = true` creates the file, or fails if it already exists.

```
   attempt 1: created
   attempt 2: PathAlreadyExists
```

The check and the create happen in one step.

That matters when two programs run at the same time.

If we check first with `statFile` and then create, the other program can create the file between our two calls.

With `.exclusive = true`, only one of them succeeds.

## Append

Neither `createFile` nor `openFile` has an append option.

So we open the file, and start the writer at the end.

```
   started
   loaded 3 items
   stopped
```

`writer.seekTo(try file.length(io))` moves the writer to the current end of the file.

Then each new line goes after the old ones.

We open the file with `.mode = .read_write`, not `.write_only`.

The reason is WASI, where this program runs.

On WASI, Zig asks for the right to read a file's size only when the file is opened for reading.

So `file.length` on a write-only file fails with `AccessDenied` there. On Linux and macOS, `.write_only` works.

There is one more limit.

Seeking to the end and writing are two separate steps.

If two programs append to the same file at the same time, both can seek to the same end and write over each other.

[Two Writers, One File](https://www.ziglang.in/learn/storage/filelock/) shows that happening, and the lock that prevents it.

## The forgotten flush

This part of the program writes a line and then closes the file without calling `flush()`.

```
   buffered 33 bytes, file length 0
   after close: 0 bytes on disk
```

`writeAll` copied the 33 bytes into the writer's buffer.

Nothing reached the file, because the buffer was not full.

`close` closes the file. It does not know about our buffer.

So the bytes are lost, and there is no error.

The fix is to call `flush()` before closing.

In a function that returns early on errors, we put it right after the last write, and let `try` report a failed flush.

## Replacing a file in one step

Say a program rewrites `config.txt` while another program reads it.

If the reader opens the file halfway through the write, it gets half a config.

If the writer crashes halfway, the file stays half written.

`createFileAtomic` avoids both problems.

It writes to a new temporary file in the same directory.

When we call `replace`, it renames the temporary file to `config.txt`.

On Linux and macOS, a rename inside one directory happens in one step. A reader sees the old file or the new file, never a mix.

```
   while writing: "port = 8080\n"
   after replace: "port = 9090\n"
```

While we were writing, `config.txt` still held the old content.

The second block fails on purpose. It writes half a line and returns before `replace`.

```
   after a failed write: "port = 9090\n"
   files in the directory: 5
```

`deinit` runs from the `defer` and deletes the temporary file.

The old content is untouched, and no temporary file is left behind.

We always call `deinit`, even after a successful `replace`. It is safe to call in both cases.

The option `.replace = true` must match the call we make at the end.

`replace` overwrites an existing file.

`link` is the other choice. It fails with `PathAlreadyExists` if the file is already there, like `.exclusive = true`.

## Which one to use

For a new file we write once, `createFile` with the defaults.

For a log, open and seek to the end.

For a file another program reads, or one that must never be half written, `createFileAtomic`.

In every case, flush before close.
