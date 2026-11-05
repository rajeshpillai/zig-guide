# The Environment

> A map from string to string. The parent process selects the map, and your process gets the map at startup.

The environment is a list of `KEY=value` strings. The parent process selected
the list, and the kernel copied the list into your address space at startup.
The environment belongs only to your process. After startup, a change that you
make to the environment does not get to any other process that runs.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The real environment. The startup code parsed it into a map before
    // main. This program runs in a wasm sandbox that has no parent process.
    // Thus the count is the real value, not a placeholder.
    const env = init.environ_map;
    try out.print("inherited variables: {d}\n", .{env.count()});
    try out.print("PATH: {?s}\n\n", .{env.get("PATH")});

    // A put into the map does not change any other process. The map is the
    // copy that belongs to this program. A child gets a copy at spawn time.
    try env.put("ZIG_GUIDE", "live");
    try env.put("EDITOR", "vim");
    try out.print("after two puts: {d}\n", .{env.count()});
    try out.print("ZIG_GUIDE: {?s}\n", .{env.get("ZIG_GUIDE")});
    try out.print("contains EDITOR: {}\n", .{env.contains("EDITOR")});

    _ = env.swapRemove("EDITOR");
    try out.print("after removing it: {?s}\n\n", .{env.get("EDITOR")});

    // A name must not be empty and must not contain '='. You cannot escape
    // the separator. Thus you cannot read back a key that contains '='.
    try out.print("\"HOME\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("HOME")});
    try out.print("\"A=B\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("A=B")});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`14-os.environment`)*

## The map is ready at startup

```zig
pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const path = env.get("PATH");
}
```

`init.environ_map` is a `*std.process.Environ.Map`. The startup code filled
the map from the raw block before the call to `main`. The startup code
allocated the map with the same `gpa` that is on `init`. You do not free the
map, and you do not build the map.

In the playground above, the count is 0. The count is the real result, not a
stub. A wasm module in a browser tab has no parent process, so the module
inherits no environment. Thus the environment is really empty.

In the playground, `env.get("PATH")` returns `null`. A program must be ready
for this result on all platforms. If you did not set a variable yourself, the
variable can be absent.

## Your copy belongs to you

```zig
try env.put("ZIG_GUIDE", "live");
```

This line changes the map of this program and nothing else. It does not
change the shell that started your program. Alone, it does not change the
environment of a child process either.

A child process inherits a copy of a block. The block is the one that existed
when you spawned the child. When you spawn the child, you select the block. If
you give `null`, the child gets the environment of the parent.

Many people expect the other direction to work, but it does not work. No call
lets a program change the environment of its parent. Thus a tool that must
change your shell prints text, and the shell evaluates that text. The
kernel copied the environment at fork time, and the copies have no connection.

## Two rules for keys

A name must not be empty. A name must not contain `=` or a NUL byte. The map
can tell you if a key is valid:

```zig
std.process.Environ.Map.validateKeyForPut("A=B") // false
```

You cannot escape the separator. A block is a flat list of `KEY=VALUE`
strings, and the split occurs at the first `=`. Thus you can write a key that
contains `=`, but you cannot read the key back as you intended.

All bytes after the first `=` are the value. The value can contain newlines,
spaces and more `=` signs. For this reason, `PATH` works, and a value never
needs quotes at this level. The quotes that you write in a shell belong to
the shell. The shell removes the quotes before the string gets to your
program.

## Case, and the platform that is different

On POSIX, names are case-sensitive. On Windows, names are case-insensitive,
and the block is UTF-16. Thus on Windows, `Path` and `PATH` are the same
variable. `Environ.Map` follows the target platform of the build.

Code that reads one spelling and writes a different spelling works on
Windows. On all other platforms, the code is wrong, and no error tells you.
Thus select the usual upper-case spelling, and use the same spelling in both
places.
