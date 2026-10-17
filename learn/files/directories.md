# Directories

> Create a tree of directories, list one level, walk every level, rename a directory and delete the whole tree.

A directory is a list of names.

Each name points to a file or to another directory.

The program below builds a small project tree, lists it two ways, renames part of it, and deletes all of it.

```zig
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const cwd = Io.Dir.cwd();

    // 1. Create a small project tree. createDirPath makes every missing
    //    directory on the way, like `mkdir -p`.
    try out.print("1. create\n", .{});
    try cwd.createDirPath(io, "project/src/util");
    try cwd.createDirPath(io, "project/docs");
    const files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "project/README.md", .data = "# project\n" },
        .{ .path = "project/src/main.zig", .data = "pub fn main() void {}\n" },
        .{ .path = "project/src/util/math.zig", .data = "pub fn add(a: u8, b: u8) u8 {\n    return a + b;\n}\n" },
        .{ .path = "project/docs/notes.txt", .data = "todo\n" },
    };
    for (files) |f| try cwd.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    try out.print("   {d} files written\n", .{files.len});

    // Creating a directory that exists is an error. createDirPath is not.
    if (cwd.createDir(io, "project", .default_dir)) |_| {
        try out.print("   createDir again: ok\n", .{});
    } else |err| try out.print("   createDir again: {t}\n", .{err});
    try cwd.createDirPath(io, "project/src");
    try out.print("   createDirPath again: ok\n", .{});

    // 2. One level, sorted.
    try out.print("2. list project/\n", .{});
    {
        var dir = try cwd.openDir(io, "project", .{ .iterate = true });
        defer dir.close(io);
        try listSorted(io, gpa, dir, out);
    }

    // 3. Every level, sorted, with sizes.
    try out.print("3. walk project/\n", .{});
    try walkSorted(io, gpa, cwd, "project", out);

    // 4. Rename a directory. Everything inside it moves too.
    try out.print("4. rename project/docs -> project/doc\n", .{});
    try cwd.rename("project/docs", cwd, "project/doc", io);
    if (cwd.statFile(io, "project/doc/notes.txt", .{})) |st| {
        try out.print("   project/doc/notes.txt is {d} bytes\n", .{st.size});
    } else |err| return err;

    // 5. Delete. deleteDir only removes an empty directory.
    try out.print("5. delete\n", .{});
    if (cwd.deleteDir(io, "project")) |_| {
        try out.print("   deleteDir: ok\n", .{});
    } else |err| try out.print("   deleteDir: {t}\n", .{err});
    try cwd.deleteTree(io, "project");
    if (cwd.statFile(io, "project", .{})) |_| {
        try out.print("   deleteTree: project still exists\n", .{});
    } else |err| try out.print("   deleteTree: done, stat now gives {t}\n", .{err});
}

const Item = struct {
    name: []const u8,
    kind: Io.File.Kind,

    fn lessThan(_: void, a: Item, b: Item) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn listSorted(io: Io, gpa: Allocator, dir: Io.Dir, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The order entries come back in is up to the filesystem. Collect them
    // and sort, so the output is the same everywhere.
    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // `entry.name` is only valid until the next call to `next`.
        try items.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(Item, items.items, {}, Item.lessThan);
    for (items.items) |item| try out.print("   {t:<9} {s}\n", .{ item.kind, item.name });
}

fn walkSorted(io: Io, gpa: Allocator, parent: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try parent.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var items: std.ArrayList(Item) = .empty;
    var total: u64 = 0;
    while (try walker.next(io)) |entry| {
        try items.append(arena, .{ .name = try arena.dupe(u8, entry.path), .kind = entry.kind });
        if (entry.kind == .file) {
            // `entry.dir` is the directory that holds this entry, so stat
            // by basename there rather than building a path from the top.
            total += (try entry.dir.statFile(io, entry.basename, .{})).size;
        }
    }
    std.mem.sort(Item, items.items, {}, Item.lessThan);
    for (items.items) |item| {
        const depth = std.mem.count(u8, item.name, "/");
        try out.splatByteAll(' ', 3 + 2 * depth);
        try out.print("{s}{s}\n", .{ std.Io.Dir.path.basename(item.name), if (item.kind == .directory) "/" else "" });
    }
    try out.print("   {d} entries, {d} bytes in files\n", .{ items.items.len, total });
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`24-files.directories`)*

## Creating a tree

`createDirPath(io, "project/src/util")` creates `project`, then `project/src`, then `project/src/util`.

It skips any that already exist.

This is what `mkdir -p` does in a shell.

`createDir` creates exactly one directory, and its parent must already exist.

The two also differ when the directory is already there.

```
   createDir again: PathAlreadyExists
   createDirPath again: ok
```

`createDir` reports an error.

`createDirPath` succeeds, because the path it was asked for exists.

Use `createDirPath` to make sure a directory is there before writing into it.

Use `createDir` when the directory should be new, like `.exclusive = true` for a file.

## Listing one level

`Dir.cwd()` is not opened for listing.

Its doc comment says that iterating over it is illegal behaviour.

So we open the directory we want with `.iterate = true` first, and list that.

<SnippetSource name="24-files.directories" decl="listSorted" />

`dir.iterate()` returns an iterator, and `it.next(io)` returns one entry at a time, or `null` at the end.

Each entry has a `name` and a `kind`.

```
   file      README.md
   directory docs
   directory src
```

The order the entries come back in is decided by the filesystem.

It is not alphabetical, and it is not the order the files were created.

It can differ between two machines, and between two runs on the same machine after files are added and deleted.

This program runs on a real disk in CI and in memory in your browser, and the two give different orders.

So we collect the names and sort them before printing.

Any output that depends on a directory listing needs the same step, or a test of it will fail on some machines.

`README.md` comes first because the sort compares bytes, and uppercase letters have smaller byte values than lowercase ones.

The names are copied with `arena.dupe`.

`entry.name` points into the iterator's buffer, and the next call to `next` can overwrite it. This is the same rule as for lines in [Reading Line by Line](https://www.ziglang.in/learn/files/read-lines/#keeping-a-line).

## Walking every level

<SnippetSource name="24-files.directories" decl="walkSorted" />

`dir.walk(gpa)` visits every entry under the directory, at every depth.

It needs an allocator, because it keeps a stack of the directories it has opened.

Each entry has a `path` relative to the starting directory, like `src/util/math.zig`.

It also has `basename`, the last part of that path, and `dir`, the open directory that holds the entry.

```
   README.md
   docs/
     notes.txt
   src/
     main.zig
     util/
       math.zig
   7 entries, 87 bytes in files
```

The walk order also comes from the filesystem, so we sort by path here too.

Sorting full paths puts each directory right before its contents.

To add up file sizes, we call `entry.dir.statFile(io, entry.basename, .{})`.

That asks the directory holding the file for its details, using only the file's own name.

We could build the full path from the top instead, but that path gets longer with every level. Very deep trees can exceed the longest path the system accepts.

## Renaming a directory

`cwd.rename("project/docs", cwd, "project/doc", io)` renames the directory.

```
   project/doc/notes.txt is 5 bytes
```

The files inside move with it.

Nothing is copied. Only the name in the parent directory changes, so renaming a directory with a million files is as fast as renaming an empty one.

`rename` takes a directory for each side, so it can also move an entry into another directory.

Both directories have to be on the same filesystem. Moving between two disks is a copy followed by a delete, and `rename` does not do that for us.

## Deleting

```
   deleteDir: DirNotEmpty
   deleteTree: done, stat now gives FileNotFound
```

`deleteDir` removes one empty directory.

`project` still has files in it, so it fails with `DirNotEmpty`.

`deleteTree` removes the directory and everything under it.

It is the same as `rm -r` in a shell, and it has the same risk. A wrong path deletes the wrong tree, and there is no undo.

It also succeeds when the path does not exist. So `deleteTree` is safe to call as a cleanup step, whether or not an earlier step created anything.

## Directories are handles

Every operation here goes through a `Dir` value.

`cwd.openDir(io, "project", ...)` returns a new `Dir` for `project`, and `dir.close(io)` closes it.

Paths are relative to the `Dir` they are given to.

[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/#directories-are-handles-not-strings) explains why std works through open directories instead of path strings.
