# When Things Go Wrong

> What stat tells you, six file operations that fail and the error from each, messages for a person, and how to delete a half-written file.

Each chapter in this section handles some errors. This chapter looks at the errors together.

A file operation can fail for reasons that the program does not control:

- A different program deleted the file.
- The path is incorrect.
- The disk is full.
- A different program changed something.

Zig does not hide these failures. Each failure is an error value with a name. The return type of the function gives a list of all the errors that the function can return.

The program below makes six operations fail intentionally. It prints the result of each operation.

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

    // 1. stat: what is at a path. stat does not open the path.
    try out.print("1. stat\n", .{});
    for ([_][]const u8{ "notes.txt", "archive" }) |path| {
        const st = try dir.statFile(io, path, .{});
        try out.print("   {s:<10} kind {t}", .{ path, st.kind });
        // The filesystem decides the size of a directory (4096 on ext4, 0 in
        // memory). The size tells you nothing about the contents.
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

/// The error that an operation returned. The operation must fail. Thus, on
/// a success, the function closes the file and returns a mistake.
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
    // Without `.allow_directory = false`, the open of a directory succeeds.
    // The error comes only at the first read, and each system gives a
    // different error.
    const file = try dir.openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    try out.print("loaded {d} bytes\n", .{n});
}

/// One sentence for each error that a person can correct. The function
/// gives the name of all other errors, because a hidden error helps nobody.
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

/// Writes two lines of a report, then fails at the third line, as a real
/// check on the data can fail.
fn exportReport(io: Io, dir: Io.Dir, name: []const u8, cleanup: bool) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    // Runs only if this function returns an error. Deferred statements run
    // in reverse order. Thus this delete runs before `defer` closes the file.
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

`dir.statFile(io, path, .{})` asks what is at a path. It does not open the path.

```
   notes.txt  kind file, size 6
   archive    kind directory
```

The result is a `Stat`:

- `kind` tells you if the path is a file, a directory, or a different thing, for example a symbolic link.
- `size` is the length of a file in bytes.

For a directory, the size has no useful meaning. On Linux with ext4, the size is 4096. In the in-memory directory of the browser, the size is 0. Thus the program prints the size only for files.

`Stat` also has `mtime`, the time of the last change to the file, and `atime`, the time of the last read. This program does not print these times, for two reasons:

- A real time is different on each run. Thus CI cannot compare it.
- The in-memory directory in your browser does not store times. Each time in that directory is 0.

## Six failures

```
   open a file that is not there:     FileNotFound
   create a file in a missing dir:    FileNotFound
   open a directory as a file:        IsDir
   use a file as a directory:         NotDir
   deleteFile on a directory:         IsDir
   deleteFile on a missing file:      FileNotFound
```

`createFile` creates a file, but not the directory for the file. If `drafts` does not exist, the error is `FileNotFound`. This is the same error as for a file that does not exist.

The third line opens `archive` with `.allow_directory = false`. This option is important.

By default, `openFile` can open a directory. Then the error comes later, at the first read. The system decides which error comes at that time. On Linux, the error is `IsDir`. Under the WASI of Node, the error is `AccessDenied`.

With `.allow_directory = false`, the open operation fails with `IsDir` on all systems. That error is easier to handle, and easier to explain to a person.

`notes.txt/x` asks for an item in `notes.txt`, but `notes.txt` is a file. The error is `NotDir`.

`deleteFile` removes only files. For a directory, use `deleteDir` or `deleteTree`, from the [Directories](https://www.ziglang.in/learn/files/directories/) chapter.

## Errors as messages

A person who uses the program must know what to do next. `FileNotFound` is the name of an error. It is not an instruction.

```zig
/// One sentence for each error that a person can correct. The function
/// gives the name of all other errors, because a hidden error helps nobody.
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
```

*Quoted from the source: `message` from `snippets/24-files/failures.zig`.*

`message` changes each error that a person can correct into a sentence.

```
   missing.txt  not found: check the name and the folder
   archive      that is a folder, not a file
   notes.txt/x  part of the path is a file, not a folder
   notes.txt    loaded 6 bytes
```

All other errors go to the `else` branch. That branch shows the name of the error with `@errorName`. The name is not easy for a person to read, but it is correct.

Do not use one message, such as "could not load file", for all errors. That message hides the one detail that a person needs to correct the problem.

In a larger program, the `else` branch is also the location where you log the error for the maintainer of the program.

`message` takes `anyerror`. Thus the function accepts all errors. But the compiler cannot tell you when the `switch` has no case for an error. With a specific error set, a `switch` without `else` does not compile when someone adds a new error to the set.

## Delete a half-written file

```zig
/// Writes two lines of a report, then fails at the third line, as a real
/// check on the data can fail.
fn exportReport(io: Io, dir: Io.Dir, name: []const u8, cleanup: bool) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    // Runs only if this function returns an error. Deferred statements run
    // in reverse order. Thus this delete runs before `defer` closes the file.
    errdefer if (cleanup) dir.deleteFile(io, name) catch {};

    var buf: [64]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll("total: 3\n");
    try w.interface.writeAll("item 1\n");
    try w.interface.flush();
    return error.InvalidItem;
}
```

*Quoted from the source: `exportReport` from `snippets/24-files/failures.zig`.*

`exportReport` writes two lines and then fails, as a real check on the data can fail.

```
   cleanup=false: InvalidItem, report.txt left behind, 16 bytes
   cleanup=true: InvalidItem, no report.txt
```

Without cleanup, the half-written report stays on disk. Later, a different program can find the report and think that it is complete.

With cleanup, the `errdefer` statement deletes the report. `errdefer` runs only when the function returns an error. When the function succeeds, `errdefer` does nothing.

The order is important here. The code has `defer file.close(io)` first and `errdefer` second. Deferred statements run in reverse order. Thus, on an error, the `errdefer` statement runs first and deletes the file. Then the `defer` statement closes the handle.

On Linux and macOS, you can delete a file that is still open. The name goes away immediately. The data goes away when the last handle closes.

For a file that replaces an old file, [Write Text Files](https://www.ziglang.in/learn/files/write-text/#replace-a-file-in-one-step) shows `createFileAtomic`. That function gives the same result, and it also keeps the old file safe.

## What this page cannot show

This page cannot cause some failures intentionally:

- `NoSpaceLeft` needs a full disk.
- `AccessDenied` for a file that the program cannot read needs file permissions, and WASI does not have them.

The code for these errors is the same as for the other errors: a name in the error set, and a branch in the `switch`.

The last failure is a crash. A write to a file puts the bytes in the memory of the operating system. Later, the system writes the bytes to the disk. If the computer loses power before that, the bytes are lost. This occurs even when each write returned without an error.

`file.sync(io)` waits until the bytes are on the disk. The call is slow. Thus programs call it only where a loss of data is important.

[A Write-Ahead Log](https://www.ziglang.in/learn/storage/kvstore/) explains when to call `sync`, and why `sync` also has limits.
