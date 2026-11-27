# Import C

> translate-c, and calling C without bindings.

Zig reads C headers directly. You do not need a binding generator, and you
do not maintain an intermediate `.zig` file.

The change is the place where Zig reads the header. Before, a builtin in your
source read the header. Now a step in your build reads the header.

## `@cImport` is gone

If you come from an older tutorial, this line does not compile:

```zig
// Removed from the language. Every tutorial written before 2026 shows this.
const c = @cImport({
    @cDefine("_GNU_SOURCE", {});
    @cInclude("stdio.h");
    @cInclude("string.h");
});
```

On current Zig, the line fails with
`error: invalid builtin function: '@cImport'`. `@cInclude` and `@cDefine` are
also removed.

Headers now come from `b.addTranslateC`, which makes an ordinary Zig module.
Import the module by the name that you gave to it:

```zig
const c = @import("c");

pub fn main() void {
    // Zig string literals are already null-terminated. Thus you can give
    // them to a `[*c]const u8` parameter without a change.
    _ = c.printf("hello from C\n");

    const len = c.strlen("abc");
    _ = c.printf("strlen(\"abc\") = %d\n", @as(c_int, @intCast(len)));
}
```

*This snippet translates the real stdio.h and string.h and links the host libc. Thus CI builds and runs it natively. Browser wasm has no headers and no libc. (`05-working-with-c.libc-from-zig`)*

All declarations of the header are still members of `c`. The difference is
that the source file does not name a header now. The build names the header.

The translate step takes one C file as its root. If a project needs several
headers, write one header that includes them:

```c
// src/c.h
#include <stdio.h>
#include <string.h>
```

```zig
// build.zig
const translate = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
translate.defineCMacro("_GNU_SOURCE", null);
```

`defineCMacro` replaces `@cDefine`. A `null` value means a macro without a
value. Then `translate.createModule()` gives the module. Give that module to
the code that needs it.

The extra step has an advantage. The build now caches and configures a C

again on each compile.

## Tell the build where to look

There are three separate jobs, in three places.

The translate step must find the headers:

```zig
translate.addIncludePath(b.path("vendor/include"));
translate.linkSystemLibrary("sqlite3", .{});
```

The module that calls the C code needs libc and the compiled C code:

```zig
const module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
    .imports = &.{.{ .name = "c", .module = translate.createModule() }},
});
module.linkSystemLibrary("sqlite3", .{});
```

Or compile the C code yourself. Zig includes a C compiler. Thus you can copy
the source files of a dependency into your project:

```zig
module.addCSourceFile(.{ .file = b.path("vendor/thing.c"), .flags = &.{"-std=c99"} });
```

Look at the type that has these methods. `addCSourceFile`, `addIncludePath`
and `linkSystemLibrary` are methods on `std.Build.Module`, not on the
executable. `exe.linkLibC()` does not exist now. For libc, set
`.link_libc = true` in the options of the module. Code that calls
`exe.addIncludePath` or `exe.linkLibC` is from the same time as `@cImport`. That
code fails in the same way.

## A full project

The parts above have a meaning only together. This is the smallest project
that uses all of the parts. Your Zig code calls a C function from a C file in
your project. No system library is necessary.

```
project/
├── build.zig
├── src/
│   └── main.zig
└── vendor/
    ├── calc.c
    └── calc.h
```

```c
// vendor/calc.h
int calc_add(int a, int b);
```

```c
// vendor/calc.c
#include "calc.h"
int calc_add(int a, int b) { return a + b; }
```

`src/main.zig` is a real snippet in this guide. Thus CI compiles and runs it
on each push:

```zig
const std = @import("std");

// The removed `@cImport` builtin made this module before. Now the build names
// the header. Thus this file does not name a header.
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // `calc_add` is an ordinary member of the module. The translation of the
    // header makes the name. The compiled `calc.c` lets the name link.
    try out.print("calc_add(2, 3) = {d}\n", .{c.calc_add(2, 3)});
    try out.flush();
}
```

*This snippet translates a vendored header and compiles a vendored .c file. The two steps need a host C compiler. CI builds and runs the snippet on each push. (`05-working-with-c.translate-c`)*

CI builds the snippet against the two C files above. The C files are next to
the snippet in `snippets/05-working-with-c/`. Your own project writes the
build below by hand. This repo makes the same steps from a marker on the
snippet.

```zig
// build.zig
const translate = b.addTranslateC(.{
    .root_source_file = b.path("vendor/calc.h"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});

const exe = b.addExecutable(.{
    .name = "demo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate.createModule() }},
    }),
});
exe.root_module.addCSourceFile(.{ .file = b.path("vendor/calc.c") });
b.installArtifact(exe);
```

The project has one header. Thus the header is the root of the translate step,
and no include path is necessary. If the root is your own header that
`#include`s several headers, `translate.addIncludePath` lets Zig find those
headers.

To read the header and to compile the C code are separate jobs. If you omit
one job, the failure is different from the failure for the other job:

```
 vendor/calc.h
       │
       │ addTranslateC reads it, once, as a build step
       ▼
   module "c"
       │
       │ imported by src/main.zig as @import("c")
       ▼
  src/main.zig
       │
       │ addCSourceFile compiles vendor/calc.c
       ▼
 build.zig links both
       │
       ▼
   executable
```

The translate step decides which declarations Zig can see. If the header does
not exist, the error gives the name of the header.

`addCSourceFile` puts the compiled function in the binary. If you forget
`addCSourceFile`, the code compiles without errors. Then the link fails with
`ld.lld: undefined symbol: calc_add`. This error is more difficult to
understand than the other error, so learn to recognise it. The line does not
come from memory. When the C file is removed from the snippet above, the build gives exactly
that line.

To use a system library in place of the vendored file, change two lines:

- `linkSystemLibrary("sqlite3", .{})` on the translate step, so that the
  translate step finds the header.
- The same call on the module, so that the build links the library.

## What translates and what does not

Types, functions and simple `#define` constants translate correctly.
**Function-like macros do not translate correctly.** They are C syntax, not C
semantics, and Zig cannot always give them a meaning. If you need a
function-like macro, write it again in Zig.

The command `zig translate-c header.h` still exists. It prints exactly what
the build step makes. To see the result for a given header, this command is
the fastest method.

## Strings

C strings are `[*c]const u8` and null-terminated. Zig string literals are
already null-terminated. Thus you can give a literal to C without a
conversion. For a C string that comes to Zig, `std.mem.span(ptr)` finds the
terminator and returns a slice.

## Binding generators in other languages

Other languages use a separate tool for the same problem:

- Python has ctypes, cffi and a generator.
- Rust has bindgen.
- Go has cgo, with its own dialect of comments.

Each of these tools reads the header and writes code in a third file. You must
then make that file again, commit it, and keep it the same as the header.

Zig reads the header as part of the build. The build makes the binding again
when the header changes. Thus the binding is always the same as its header.
You do not commit a generated file, and you do not make one again by hand. If
you update the C library, a changed signature is a compile error on the same
day.

Because the build makes the binding again each time, the X11 chapter of this
guide can link against the real system Xlib in CI. The X11 snippet does not
run. But CI translates the header and type-checks the calls. Thus a change in libX11 makes
the build fail. Without this check, nobody would see the change until a person
read the page.

## Error handling across the boundary

C reports a failure with a return value and with a global `errno`. After
translation, neither of the two has a useful meaning. Thus the wrapper that you
write for a C library is also the place where the C conventions become Zig
errors:

```zig
pub fn open(path: [:0]const u8) !Handle {
    const h = c.thing_open(path.ptr);
    if (h == null) return error.OpenFailed;
    return .{ .ptr = h.? };
}
```

Write a wrapper of this type one time for each function. The work is
repetitive, and it is all the work that the wrapper must do. In return, the
rest of the program uses `try`. No caller has a return code that it can
forget to check.

Ownership is the other half. Each C library has its own rules about who frees
which memory. In the wrapper, those rules become `defer` and `errdefer` in the
scope of the Zig caller. Usually, a handle type with a `deinit` method is the
correct shape, because then you can see the pair of calls.

## Why the snippets here have no Run button

CI compiles and runs the two programs above on each push, with the compiler
that the footer names. Neither program runs in your browser.

To translate a header, you need real C headers and a libc for the target. The
wasm sandbox of these pages has neither. Thus the two programs are host
builds. CI runs them on Linux and diffs their output. The page shows you the
source without a Run button. The page does not ship a `.wasm` that cannot
work.

Only the `build.zig` on this page is an illustration, not a checked file. Your
project writes those steps by hand. This repo generates the steps from a
marker on the snippet. Thus the two cannot be the same file. But the calls
are the same calls, and each run of `zig build` compiles them. That compile
found the most recent API changes that broke this page.

For more C code that CI verifies on each run, see these chapters:

- [SQLite from Zig](https://www.ziglang.in/learn/how-to/databases/sqlite-basic/), which links the
  real libsqlite3.
- [The X11 chapter](https://www.ziglang.in/learn/graphics/on-screen/), which links the real Xlib.
