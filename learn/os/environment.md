# The Environment

> A string-to-string map the parent process chose, handed over at startup.

The environment is a list of `KEY=value` strings that the parent process
decided on and the kernel copied into your address space at startup. It is not
a system-wide setting, it is not shared, and nothing you do to it after
startup reaches any other running process.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The real environment, already parsed into a map by the startup code.
    // This program is running in a wasm sandbox with no parent process to
    // inherit from, so the count is the honest answer rather than a stub.
    const env = init.environ_map;
    try out.print("inherited variables: {d}\n", .{env.count()});
    try out.print("PATH: {?s}\n\n", .{env.get("PATH")});

    // Putting a variable in the map does not change any other process. The
    // map is this program's copy; a child gets one when it is spawned.
    try env.put("ZIG_GUIDE", "live");
    try env.put("EDITOR", "vim");
    try out.print("after two puts: {d}\n", .{env.count()});
    try out.print("ZIG_GUIDE: {?s}\n", .{env.get("ZIG_GUIDE")});
    try out.print("contains EDITOR: {}\n", .{env.contains("EDITOR")});

    _ = env.swapRemove("EDITOR");
    try out.print("after removing it: {?s}\n\n", .{env.get("EDITOR")});

    // A name may not be empty and may not contain '='. The separator is not
    // escapable, so a key holding one could never be read back.
    try out.print("\"HOME\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("HOME")});
    try out.print("\"A=B\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("A=B")});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`14-os.environment`)*

## It arrives already parsed

```zig
pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const path = env.get("PATH");
}
```

`init.environ_map` is a `*std.process.Environ.Map` that the startup code
populated from the raw block before `main` was called, allocated with the same
`gpa` on `init`. You do not free it and you do not build it.

The count is 0 in the playground above. That is not a stub standing in for the
real thing. A wasm module in a browser tab has no parent process to inherit an
environment from, so the honest answer is that there are none. Reading `PATH`
there returns `null`, which is exactly what a program should be prepared for
on any platform. A variable you did not set is a variable that may not be
there.

## Your copy is yours

```zig
try env.put("ZIG_GUIDE", "live");
```

That changes this program's map and nothing else. It does not modify the shell
that launched you. On its own it does not even modify what a child of yours
will see. A child inherits a copy of the block that existed when it was
spawned, and you choose which block that is when you spawn it. Leave it null
and the child gets the parent's.

The direction that surprises people is the one that does not work. There is no
call that lets a program change its parent's environment. It is the only way.
The environment was copied at fork time, and the copies were never connected.

## Keys have two rules

A name may not be empty, and may not contain `=` or a NUL byte. The map will
tell you:

```zig
std.process.Environ.Map.validateKeyForPut("A=B") // false
```

The separator is not escapable. A block is a flat list of `KEY=VALUE` strings,
split on the first `=`. So a key containing one could be written but never
read back as what you meant. Everything after that first byte is value,
including newlines, spaces and further `=` signs, which is why `PATH` works
and why a value never needs quoting at this level. The quoting you write in a
shell is the shell's, and it is gone by the time the string reaches you.

## Case, and the platform that disagrees

Names are case-sensitive on POSIX and case-insensitive on Windows, where the
block is UTF-16 and `Path` and `PATH` are the same variable. `Environ.Map`
matches the platform it was built for. Code that reads one spelling and writes
another is fine on Windows and quietly broken everywhere else, so pick the
conventional upper-case spelling and use it in both places.
