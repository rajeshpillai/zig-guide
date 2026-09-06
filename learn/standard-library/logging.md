# Logging

> One log function, chosen at the root and known at compile time.

```zig
const std = @import("std");

// `std_options` is read from the root of the program at compile time, so it
// only takes effect here because this snippet is an executable (a `zig test`
// file is not the root, and its std_options would be ignored). Setting the
// level to .debug compiles in every level; a release build drops the chatty
// ones by default. A per-scope cap overrides the global level for one area.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn }, // .noisy logs only from warn up
    },
};

// A scoped logger tags every line with its subsystem, so you can raise or
// lower one area without touching the rest.
const net = std.log.scoped(.net);

pub fn main(init: std.process.Init) void {
    _ = init;

    // Every level goes to stderr through std.options.logFn. Each call is
    // compiled in or out by the configured level, not gated at run time.
    std.log.debug("resolving host", .{});
    std.log.info("connected in {d}ms", .{12});
    std.log.warn("slow response, retrying", .{});
    std.log.err("giving up after {d} tries", .{3});

    net.info("scoped line, tagged (net)", .{});

    // logEnabled is comptime-known, so an unused level costs nothing at all.
    std.debug.assert(std.log.logEnabled(.debug, .default)); // on, we set .debug
    std.debug.assert(!std.log.logEnabled(.info, .noisy)); // capped at .warn
    std.debug.assert(std.log.logEnabled(.warn, .noisy));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.logging`)*

## Four levels, tagged by scope

`std.log` gives you `debug`, `info`, `warn`, and `err`. Each takes a
compile-time format string and its arguments, the same shape as everywhere
else. `std.log.scoped(.name)` returns the same four functions but tags every
line with a subsystem, so a reader (or a filter) can tell where a message came
from. The default scope is `.default`.

The output above is the standard formatter writing to stderr. In your browser
the playground shows stdout and stderr together, which is why you see the log
lines at all.

## The level is set at the root, and it is a compile-time gate

The whole configuration lives in one declaration read from the **root** of the
program:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn },
    },
};
```

Two things follow from "root," and both bite people:

- It must be in the root source file (the one with `main`). A `pub const
  std_options` in a library file, or in a `zig test` file, is **ignored** —
  the test runner is the root there, not your file. That is exactly why this
  chapter's snippet is a program rather than a test.
- A call below the active level is compiled *out*, not skipped at run time.
  `std.log.debug` in a release build costs nothing because it is not there.
  `std.log.logEnabled(level, scope)` reports this, and is itself
  comptime-known.

`log_scope_levels` caps individual subsystems: above, `.noisy` is quiet until
`warn` even though the global level is `.debug`. Raise or lower one area
without touching the rest.

## Replacing the formatter

`std.Options.logFn` is the single function every message passes through.
Override it to change the format, add timestamps, route to a file, or emit
structured JSON:

```zig
pub const std_options: std.Options = .{
    .logFn = myLogFn,
};

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // ... format `level`, `scope`, and `fmt`/`args` however you like ...
}
```

Because there is one seam, a whole program's logging changes in one place, and
libraries that call `std.log` inherit it for free without knowing it happened.
