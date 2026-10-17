# When Things Go Wrong

> What stat tells us, six file operations that fail and the error each one names, messages a person can act on, and cleaning up a half-written file.

Every chapter in this section has handled a few errors along the way.

This one looks at them together.

A file operation can fail for reasons the program does not control.

The file was deleted, the path is wrong, the disk is full, or another program changed something.

Zig does not hide these failures. Each one is an error value with a name, and the function's return type lists every error it can return.

The program below makes six operations fail on purpose, and prints what each one returns.

```zig
const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello\n" });
    try dir.createDirPath(io, "archive");

    // 1. stat: what is at a path, without opening it.
    try out.print("1. stat\n", .{});
    for ([_][]const u8{ "notes.txt", "archive" }) |path| {
        const st = try dir.statFile(io, path, .{});
        try out.print("   {s:<10} kind {t}", .{ path, st.kind });
        // A directory's size is up to the filesystem (4096 on ext4, 0 in
        // memory) and says nothing about what is in it.
        if (st.kind == .file) try out.print(", size {d}", .{st.size});
        try out.writeByte('\n');
    }

    // 2. Six operations that fail, and the error each one returns.
    try out.print("2. six failures\n", .{});
    try out.print("   open a file that is not there:     {t}\n", .{fails(dir.openFile(io, "missing.txt", .{}), io)});
    try out.print("   create a file in a missing dir:    {t}\n", .{fails(dir.createFile(io, "drafts/new.txt", .{}), io)});
    try out.print("   open a directory as a file:        {t}\n", .{fails(dir.openFile(io, "archive", .{ .allow_directory = false }), io)});
    try out.print("   use a file as a directory:         {t}\n", .{fails(dir.openFile(io, "notes.txt/x", .{}), io)});
    try out.print("   deleteFile on a directory:         {t}\n", .{failsVoid(dir.deleteFile(io, "archive"))});
    try out.print("   deleteFile on a missing file:      {t}\n", .{failsVoid(dir.deleteFile(io, "missing.txt"))});

    // 3. The same errors as messages for a person.
    try out.print("3. messages\n", .{});
    for ([_][]const u8{ "missing.txt", "archive", "notes.txt/x", "notes.txt" }) |path| {
        try out.print("   {s:<12} ", .{path});
        loadNotes(io, dir, path, out) catch |err| try out.print("{s}\n", .{message(err)});
    }

    // 4. A write that fails halfway, with and without cleanup.
    try out.print("4. cleanup\n", .{});
    for ([_]bool{ false, true }) |cleanup| {
        exportReport(io, dir, "report.txt", cleanup) catch |err| {
            try out.print("   cleanup={}: {t}, ", .{ cleanup, err });
        };
        if (dir.statFile(io, "report.txt", .{})) |st| {
            try out.print("report.txt left behind, {d} bytes\n", .{st.size});
            try dir.deleteFile(io, "report.txt");
        } else |_| {
            try out.print("no report.txt\n", .{});
        }
    }

    try dir.deleteFile(io, "notes.txt");
    try dir.deleteDir(io, "archive");
}

/// The error an operation returned. The operation is expected to fail, so
/// a success is closed and reported as a mistake in this program.
fn fails(result: anytype, io: Io) anyerror {
    if (result) |file| {
        file.close(io);
        return error.UnexpectedSuccess;
    } else |err| return err;
}

fn failsVoid(result: anytype) anyerror {
    if (result) |_| return error.UnexpectedSuccess else |err| return err;
}

fn loadNotes(io: Io, dir: Io.Dir, path: []const u8, out: *Io.Writer) !void {
    // Without `.allow_directory = false`, opening a directory succeeds and
    // the error only arrives on the first read, and differs by system.
    const file = try dir.openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    try out.print("loaded {d} bytes\n", .{n});
}

/// One sentence per error a person can act on. Everything else is printed
/// by name, because hiding it helps nobody.
fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "not found: check the name and the folder",
        error.IsDir => "that is a folder, not a file",
        error.NotDir => "part of the path is a file, not a folder",
        error.AccessDenied, error.PermissionDenied => "no permission to read it",
        error.NoSpaceLeft => "the disk is full",
        else => @errorName(err),
    };
}

/// Writes three lines of a report. The third one fails, as a real check
/// on the data might.
fn exportReport(io: Io, dir: Io.Dir, name: []const u8, cleanup: bool) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    // Runs only if this function returns an error. `defer` above still
    // closes the file first, because defers run in reverse order.
    errdefer if (cleanup) dir.deleteFile(io, name) catch {};

    var buf: [64]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll("total: 3\n");
    try w.interface.writeAll("item 1\n");
    try w.interface.flush();
    return error.InvalidItem;
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.failures`)*

## What is at a path

`dir.statFile(io, path, .{})` asks what is at a path, without opening it.

```
   notes.txt  kind file, size 6
   archive    kind directory
```

The result is a `Stat`.

`kind` says whether the path is a file, a directory, or something else, like a symbolic link.

`size` is the length of a file in bytes.

For a directory, the size means nothing useful. On Linux with ext4 it is 4096, and in the browser's in-memory directory it is 0. So the program prints it only for files.

`Stat` also has `mtime`, the time the file was last changed, and `atime`, the time it was last read.

This program does not print them, for two reasons.

A real time is different on every run, so CI could not compare it.

And the in-memory directory in your browser does not store times at all. Every time there is 0.

## Six failures

```
   open a file that is not there:     FileNotFound
   create a file in a missing dir:    FileNotFound
   open a directory as a file:        IsDir
   use a file as a directory:         NotDir
   deleteFile on a directory:         IsDir
   deleteFile on a missing file:      FileNotFound
```

`createFile` creates a file, but not the directory it goes in. If `drafts` does not exist, the error is `FileNotFound`, the same as a missing file.

The third line opens `archive` with `.allow_directory = false`.

That option matters.

By default `openFile` is allowed to open a directory, and the error arrives later, on the first read.

Which error arrives then depends on the system. It is `IsDir` on Linux, and `AccessDenied` under Node's WASI.

With `.allow_directory = false`, the open itself fails with `IsDir` on every system. That is easier to handle, and easier to explain to a person.

`notes.txt/x` asks for something inside `notes.txt`, which is a file. The error is `NotDir`.

`deleteFile` only removes files. For a directory, use `deleteDir` or `deleteTree`, from the [Directories](https://www.ziglang.in/learn/files/directories/) chapter.

## Errors as messages

A person using the program needs to know what to do next. `FileNotFound` is the name of an error, not an instruction.

<SnippetSource name="24-files.failures" decl="message" />

`message` turns the errors a person can act on into a sentence.

```
   missing.txt  not found: check the name and the folder
   archive      that is a folder, not a file
   notes.txt/x  part of the path is a file, not a folder
   notes.txt    loaded 6 bytes
```

Every other error goes to the `else` branch, and is shown by its name with `@errorName`.

The name is not friendly, but it is true.

A message like "could not load file" for every error would hide the one detail someone needs to fix the problem.

In a larger program, the `else` branch is also where we log the error for whoever maintains the program.

`message` takes `anyerror`, so it accepts any error.

The price is that the compiler cannot tell us when a case is missing. With a specific error set, a `switch` without `else` fails to compile when a new error is added.

## Cleaning up after a failure

<SnippetSource name="24-files.failures" decl="exportReport" />

`exportReport` writes two lines, then fails, like a real check on the data might.

```
   cleanup=false: InvalidItem, report.txt left behind, 16 bytes
   cleanup=true: InvalidItem, no report.txt
```

Without cleanup, the half-written report stays on disk.

Another program could find it later and think it is complete.

With cleanup, the `errdefer` deletes it.

`errdefer` runs only when the function returns an error. On success, it does nothing.

The order matters here.

`defer file.close(io)` was written first, and `errdefer` second.

Defers run in reverse order, so on an error the `errdefer` runs first and deletes the file, and then `defer` closes the handle.

On Linux and macOS, deleting a file that is still open works: the name goes away at once, and the data goes when the last handle is closed.

For a file that replaces an old one, [Writing Text Files](https://www.ziglang.in/learn/files/write-text/#replacing-a-file-in-one-step) shows `createFileAtomic`, which gives the same result with the old file kept safe.

## What this page cannot show

Some failures cannot be made to happen here on purpose.

`NoSpaceLeft` needs a full disk.

`AccessDenied` for a file we are not allowed to read needs file permissions, and WASI does not have them.

The code for them is the same as for the others: a name in the error set, and a branch in the `switch`.

The last one is a crash.

Writing to a file puts the bytes in the operating system's memory. The system writes them to the disk later.

If the machine loses power before that, the bytes are gone, even though every write returned without an error.

`file.sync(io)` waits until the bytes are on the disk.

It is slow, so programs call it only where losing data would matter.

[A Write-Ahead Log](https://www.ziglang.in/learn/storage/kvstore/) explains when to call it, and why even `sync` has limits.
