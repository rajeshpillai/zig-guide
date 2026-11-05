# Logging

> One log function, selected at the root and known at compile time.

In Zig, `std.log` is the logging API. You set its level one time, in `std_options` in the root source file. The compiler removes a call below that level. The call is not skipped at run time.

```zig
const std = @import("std");

// Zig reads `std_options` from the root of the program at compile time. The
// declaration has an effect here only because this snippet is an executable.
// A `zig test` file is not the root, and Zig ignores its std_options. The
// level .debug compiles in each level. By default, a release build removes
// the lower levels. A maximum for one scope overrides the global level.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn }, // .noisy logs only at warn and higher
    },
};

// A scoped logger puts the subsystem name on each line. Thus you can make the
// level of one area higher or lower, and not change the other areas.
const net = std.log.scoped(.net);

pub fn main(init: std.process.Init) void {
    _ = init;

    // Each level goes to stderr through std.options.logFn. The configured
    // level decides at compile time if each call is in the build.
    std.log.debug("resolving host", .{});
    std.log.info("connected in {d}ms", .{12});
    std.log.warn("slow response, retrying", .{});
    std.log.err("giving up after {d} tries", .{3});

    net.info("scoped line, tagged (net)", .{});

    // logEnabled is known at comptime. Thus an unused level costs nothing.
    std.debug.assert(std.log.logEnabled(.debug, .default)); // on, because the level is .debug
    std.debug.assert(!std.log.logEnabled(.info, .noisy)); // capped at .warn
    std.debug.assert(std.log.logEnabled(.warn, .noisy));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.logging`)*

## Four levels, with a scope tag

`std.log` gives you `debug`, `info`, `warn`, and `err`. Each function takes a compile-time format string and its arguments. This is the same shape as in all other places.

`std.log.scoped(.name)` returns the same four functions, but each line gets a tag with a subsystem name. Thus a reader (or a filter) can see the source of a message. The default scope is `.default`.

The output above comes from the standard formatter, which writes to stderr. In your browser, the playground shows stdout and stderr together. For this reason, you can see the log lines.

## You set the level at the root, and the level is a compile-time gate

The full configuration is in one declaration. Zig reads the declaration from the **root** of the program:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .noisy, .level = .warn },
    },
};
```

The word "root" has two results, and both cause mistakes:

- The declaration must be in the root source file (the file with `main`). Zig **ignores** a `pub const
  std_options` in a library file or in a `zig test` file. In a test, the test runner is the root, not your file. For exactly this reason, the snippet in this chapter is a program and not a test.
- The compiler removes each call below the active level. The call is not skipped at run time. `std.log.debug` in a release build costs nothing, because the call is not in the build. `std.log.logEnabled(level, scope)` tells you the result, and its value is also known at comptime.

`log_scope_levels` sets a maximum level for each subsystem. In the example above, `.noisy` prints nothing below `warn`, but the global level is `.debug`. Make the level of one area higher or lower, and do not change the other areas.

## Replace the formatter

Each message goes through one function: `std.Options.logFn`. Override this function to change the format, add timestamps, send the messages to a file, or emit structured JSON:

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

Each message goes through this one function. Thus you change the logging of a full program in one place. Libraries that call `std.log` also get the change, and they need no code of their own.
