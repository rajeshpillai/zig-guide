# Directories

> Create a tree of directories, list one level, walk all levels, rename a directory and delete the full tree.

A directory is a list of names. Each name points to a file or to a different directory.

The program below makes a small project tree and lists the tree in two ways. Then it renames part of the tree and deletes all of the tree.

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

    // 1. Create a small project tree. createDirPath makes each directory
    //    in the path that does not exist, the same as `mkdir -p`.
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

    // createDir on a directory that exists is an error. createDirPath on
    // the same directory is not an error.
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

    // 3. All levels, sorted, with sizes.
    try out.print("3. walk project/\n", .{});
    try walkSorted(io, gpa, cwd, "project", out);

    // 4. Rename a directory. All of its contents move with it.
    try out.print("4. rename project/docs -> project/doc\n", .{});
    try cwd.rename("project/docs", cwd, "project/doc", io);
    if (cwd.statFile(io, "project/doc/notes.txt", .{})) |st| {
        try out.print("   project/doc/notes.txt is {d} bytes\n", .{st.size});
    } else |err| return err;

    // 5. Delete. deleteDir removes only an empty directory.
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

    // The filesystem decides the order of the entries. Collect the entries
    // and sort them, so that the output is the same on all systems.
    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // `entry.name` is valid only until the next call to `next`.
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
            // `entry.dir` is the directory that holds this entry. Thus stat
            // by basename in that directory. Do not make a path from the top.
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

## Create a tree

`createDirPath(io, "project/src/util")` creates `project`, then `project/src`, then `project/src/util`. The function skips each directory that exists already. A shell does the same with `mkdir -p`.

`createDir` creates exactly one directory, and the parent directory must exist already.

The two functions are also different when the directory exists already.

```
   createDir again: PathAlreadyExists
   createDirPath again: ok
```

`createDir` reports an error. `createDirPath` succeeds, because the path that the program asked for exists.

- To make sure that a directory exists before you write into it, use `createDirPath`.
- When the directory must be new, use `createDir`. This is the same as `.exclusive = true` for a file.

## List one level

`Dir.cwd()` is not open for a listing. Its doc comment says that iteration over `Dir.cwd()` is illegal behaviour. Thus first open the directory that you want with `.iterate = true`, then list that directory.

```zig
fn listSorted(io: Io, gpa: Allocator, dir: Io.Dir, out: *Io.Writer) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The filesystem decides the order of the entries. Collect the entries
    // and sort them, so that the output is the same on all systems.
    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // `entry.name` is valid only until the next call to `next`.
        try items.append(arena, .{ .name = try arena.dupe(u8, entry.name), .kind = entry.kind });
    }
    std.mem.sort(Item, items.items, {}, Item.lessThan);
    for (items.items) |item| try out.print("   {t:<9} {s}\n", .{ item.kind, item.name });
}
```

*Quoted from the source: `listSorted` from `snippets/24-files/directories.zig`.*

`dir.iterate()` returns an iterator. `it.next(io)` returns one entry at a time, or `null` at the end. Each entry has a `name` and a `kind`.

```
   file      README.md
   directory docs
   directory src
```

The filesystem decides the order of the entries. The order is not alphabetical, and it is not the order in which the program created the files. The order can be different on two computers. It can also be different between two runs on the same computer, after a program adds and deletes files.

In CI, this program runs on a real disk. In your browser, it runs in memory. The two give different orders.

Thus the program collects the names and sorts them before it prints them. All output that comes from a directory listing needs the same step. If not, a test of the output fails on some computers.

`README.md` is first, because the sort compares bytes. Uppercase letters have smaller byte values than lowercase letters.

The program copies the names with `arena.dupe`. `entry.name` points into the buffer of the iterator, and the next call to `next` can write over that buffer. The same rule applies to lines in [Read Line by Line](https://www.ziglang.in/learn/files/read-lines/#keep-a-line).

## Walk all levels

```zig
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
            // `entry.dir` is the directory that holds this entry. Thus stat
            // by basename in that directory. Do not make a path from the top.
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

*Quoted from the source: `walkSorted` from `snippets/24-files/directories.zig`.*

`dir.walk(gpa)` visits each entry below the directory, at all depths. The function needs an allocator, because it keeps a stack of the directories that it opened.

Each entry has these fields:

- `path`, relative to the start directory, for example `src/util/math.zig`.
- `basename`, the last part of that path.
- `dir`, the open directory that holds the entry.

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

The filesystem also decides the order of the walk. Thus the program also sorts by path here. When you sort full paths, each directory comes immediately before its contents.

To add the file sizes, the program calls `entry.dir.statFile(io, entry.basename, .{})`. This call asks the directory that holds the file for the details of the file. It uses only the name of the file.

Alternatively, the program can make the full path from the top. But that path becomes longer at each level. In a very deep tree, the path can become longer than the longest path that the system accepts.

## Rename a directory

`cwd.rename("project/docs", cwd, "project/doc", io)` renames the directory.

```
   project/doc/notes.txt is 5 bytes
```

The files in the directory move with the directory. The function copies nothing. Only the name in the parent directory changes. Thus the rename of a directory with a million files is as fast as the rename of an empty directory.

`rename` takes a directory for each side. Thus it can also move an entry into a different directory.

The two directories must be on the same filesystem. To move a file between two disks, a program must copy the file and then delete the original. `rename` does not do these steps for you.

## Delete

```
   deleteDir: DirNotEmpty
   deleteTree: done, stat now gives FileNotFound
```

`deleteDir` removes one empty directory. `project` still has files in it. Thus `deleteDir` fails with `DirNotEmpty`.

`deleteTree` removes the directory and all of the contents below it. It is the same as `rm -r` in a shell, and it has the same risk. An incorrect path deletes the incorrect tree, and you cannot undo the delete.

`deleteTree` also succeeds when the path does not exist. Thus `deleteTree` is safe as a cleanup step, also if no earlier step created the tree.

## Directories are handles

Each operation in this chapter goes through a `Dir` value. `cwd.openDir(io, "project", ...)` returns a new `Dir` for `project`, and `dir.close(io)` closes it.

Each path is relative to the `Dir` that the program gives the path to.

[Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/#a-directory-is-a-handle-not-a-string) explains why std uses open directories and not path strings.
