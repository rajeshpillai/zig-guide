# Coming from an Older Zig

> What changed between the last stable releases and the master this guide targets.

This guide targets **Zig master**: the version in the footer is the compiler
that actually compiled and ran every snippet here. If you are on a tagged
release, some of this code will not build for you.

There is no separate guide for each release. Instead, this page gives you the
**delta**: what changed, what it looks like now, and which chapter covers it.
That is usually what you need.

If your code already builds on 0.16.0, [What Changed in Zig
0.17](https://www.ziglang.in/learn/getting-started/zig-0-17/) covers only the last step, and says
which old code still compiles and which does not.

<aside>

**Why the old code below is not runnable.** Every other snippet on this site has
a Run button because CI compiled and executed it. The "before" examples here
show old code that *cannot* compile on current Zig, so they are shown as
plain code. The "after" side is verified, in the chapter
each one links to.

</aside>

## At a glance

| What | Before | Now |
| --- | --- | --- |
| `main` signature | `pub fn main() !void` | `pub fn main(init: std.process.Init) !void` |
| Writers | unbuffered, no flush | buffered, **must** `flush` |
| File API | `std.fs.File` | `std.Io.File`, and takes an `Io` |
| Array repeat | `"-" ** 5` | `@splat` (`**` is **gone**) |
| `ArrayList` | `init(allocator)` | `.empty`, allocator per call |
| Mutex | `std.Thread.Mutex` | `std.Io.Mutex`, `lock(io)` |
| Custom `format` | four parameters, used by `{}` | one writer parameter, used by `{f}` |
| Enum reflection | `info.fields[i].name` | `info.field_names[i]` |
| `addExecutable` | source file directly | `root_module` |
| Search in `std.mem` | `indexOf`, `indexOfScalar` | `find`, `findScalar` |
| Format into memory | `std.fmt.bufPrint`, `allocPrint` | `std.mem.print`, `Allocator.print` |
| Leak-checking allocator | `GeneralPurposeAllocator`, then `DebugAllocator` | `std.heap.SafeAllocator` |

---

## `main` takes an argument

This change breaks the first program you write.

```zig
// before
pub fn main() !void {
    std.debug.print("Hello\n", .{});
}
```

```zig
// now
pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello\n");
}
```

`init.io` is an **`Io` instance**: the same idea as `Allocator`, applied to
anything that can block. There is no global stdout. Your code writes only
through an `Io` that it was given.

→ [Hello World](https://www.ziglang.in/learn/getting-started/hello-world/)

## Writers are buffered ("writergate", 0.15)

```zig
// before: appeared immediately
const stdout = std.io.getStdOut().writer();
try stdout.print("{d}\n", .{42});
```

```zig
// now: nothing is written until you flush
var buf: [1024]u8 = undefined;
var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
const out = &file_writer.interface;
try out.print("{d}\n", .{42});
try out.flush();          // ← forget this and you get no output at all
```

The buffer belongs to the *interface*, so you supply it, and nothing is
allocated behind your back. A missing `flush` is a common problem when you
follow an older tutorial.

→ [Readers and Writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/)

## Filesystem moved onto `Io` (0.16)

```zig
// before
var file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();
```

```zig
// now
var dir = std.Io.Dir.cwd();
const file = try dir.openFile(io, "data.txt", .{});
defer file.close(io);
```

The rule is the same everywhere: anything that touches the disk takes the `io`
instance.

→ [Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/)

## `**` no longer exists

```zig
// before
const dashes = "-" ** 5;
```

```zig
// now
const dashes: [5]u8 = @splat('-');
```

The error message here is misleading. `**` is no longer a token at all. The
compiler reports **"binary operator `*` has whitespace on one side, but not
the other"**. That message does not tell you that `**` was removed. `++`
concatenation is unaffected.

→ [Arrays](https://www.ziglang.in/learn/language-basics/arrays/)

## `ArrayList` and hash maps are unmanaged

```zig
// before: the list stored your allocator
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append('a');
```

```zig
// now: you pass it to anything that can allocate
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);
try list.append(gpa, 'a');
```

You type more, but you can see the allocator at every call that can fail.
The same change applies to `StringHashMapUnmanaged` and
`AutoHashMapUnmanaged`.

→ [ArrayList](https://www.ziglang.in/learn/standard-library/arraylist/) · [Hash
Maps](https://www.ziglang.in/learn/standard-library/hash-maps/)

## Synchronisation moved to `Io`

```zig
// before
var mutex: std.Thread.Mutex = .{};
mutex.lock();
defer mutex.unlock();
```

```zig
// now
var mutex: std.Io.Mutex = .init;
try mutex.lock(io);
defer mutex.unlock(io);
```

`lock` can fail only because it can be *cancelled*.

Seven declarations went the same way, and none of them is deprecated or
aliased: `Mutex`, `RwLock`, `Semaphore`, `Condition`, `ResetEvent`,
`WaitGroup` and `Pool` are not on `std.Thread` any more. Everything that waits
now takes an `Io` and lives under `std.Io`. `std.Thread.spawn` stayed, along
with the four other calls that are about an OS thread. Structured concurrency
with `io.async` and `Io.Group` is the better default, and it works on targets
with no threads at all.

→ [Coming from `std.Thread`](https://www.ziglang.in/learn/concurrency/coming-from-std-thread/) ·
[Threads](https://www.ziglang.in/learn/concurrency/threads/) ·
[Concurrency](https://www.ziglang.in/learn/concurrency/async-future-group/)

## Custom `format` methods

```zig
// before
pub fn format(
    self: Point,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void { ... }
```

```zig
// now
pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("({d}, {d})", .{ self.x, self.y });
}
```

And it is **no longer invoked by `{}`**; you must ask for it with `{f}`. `{t}`
prints an enum tag name or error name.

→ [Advanced Formatting](https://www.ziglang.in/learn/standard-library/advanced-formatting/)

## Enum reflection

```zig
// before
const fields = @typeInfo(Direction).@"enum".fields;
fields[2].name;
```

```zig
// now: parallel arrays
const info = @typeInfo(Direction).@"enum";
info.field_names[2];
info.field_values[2];
```

This change is recent. It landed between `0.17.0-dev.644` and `dev.1441`.
Across about 800 commits of compiler updates, it was the only break in all 53
snippets this guide had at the time.

→ [Enums](https://www.ziglang.in/learn/language-basics/enums/)

## `build.zig`

```zig
// before
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

```zig
// now: build the module first
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

→ [Zig Build](https://www.ziglang.in/learn/build-system/zig-build/)

---

## Renames that still compile

Everything above fails with a compile error. The changes in this group do not.
The old names are still present as aliases marked `Deprecated` in the
standard library source. Code that uses them builds and runs exactly as it
did. So a tutorial, including this one, can use an old name and nothing
reports it.

```zig
// before
const at = std.mem.indexOf(u8, line, ": ");
const text = try std.fmt.bufPrint(&buf, "{d}", .{n});
const owned = try std.fmt.allocPrint(gpa, "{d}", .{n});
var debug: std.heap.DebugAllocator(.{}) = .init;
var seen: std.StaticBitSet(64) = .empty;
```

```zig
// now
const at = std.mem.find(u8, line, ": ");
const text = try std.mem.print(&buf, "{d}", .{n});
const owned = try gpa.print("{d}", .{n});
var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
var seen: std.bit_set.Static(64) = .empty;
```

The whole `indexOf` family moved to `find`. `Allocator.print` is the
allocating formatter. `SafeAllocator` also changed shape: it takes its backing
allocator as an argument, and `deinit()` returns a leak count rather than
`.ok` or `.leak`.

Every snippet on this site is checked against the list of names the standard
library marks deprecated, on the same run that compiles it. Without that
check, this guide would not have found these renames.

→ [Strings](https://www.ziglang.in/learn/standard-library/strings/) ·
[Formatting](https://www.ziglang.in/learn/standard-library/formatting/) ·
[Allocators](https://www.ziglang.in/learn/standard-library/allocators/)

---

## If you are staying on a release

You do not need to upgrade in a hurry. A tagged release is the right choice
for most work. This guide tracks master so that its code matches the current
language.

Use this page to translate: read the chapter for the concept, then change the
syntax back to your release. The *ideas* (explicit allocators, errors as
values, exhaustive switches, `defer`, comptime) have not changed at all. They
are the parts to focus on.
