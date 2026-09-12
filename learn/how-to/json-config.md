# Recipe: Loading a JSON Config

> Defaults for what's missing, validation for what's wrong, clean errors for the rest.

## The problem

Your program reads a JSON config file that users edit by hand. That means every
failure mode will happen: fields left out, values that parse but make no sense,
typo'd field names, and files that are not JSON at all. The program should take
sensible defaults for what's missing, reject what's wrong with a *specific*
error, and never crash or half-load.

## The plan

1. **Defaults live on the struct.** Give every field a default value, and
   `std.json.parseFromSlice` fills only what the input provides: an empty
   `{}` is a complete, valid config.
2. **Validation is a separate step.** The parser checks *shape* (types and
   field names); whether `port: 80` is acceptable is your policy, so it goes
   in a `validate` function with named errors.
3. **One `load` entry point** wires them together, with `errdefer` so a
   config that parses but fails validation is freed, not leaked.

```zig
const std = @import("std");

const Config = struct {
    // Every field has a default, so an empty `{}` is a valid config.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    workers: u8 = 4,
    debug: bool = false,
};

// The parser checks shape (types, field names); values are your job.
fn validate(c: Config) error{ PrivilegedPort, TooManyWorkers }!void {
    if (c.port < 1024) return error.PrivilegedPort;
    if (c.workers == 0 or c.workers > 64) return error.TooManyWorkers;
}

fn load(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    // If validation rejects it, the half-loaded config must not leak.
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn report(out: *std.Io.Writer, gpa: std.mem.Allocator, text: []const u8) !void {
    const parsed = load(gpa, text) catch |err| {
        try out.print("rejected: {t}\n", .{err});
        return;
    };
    defer parsed.deinit();
    const c = parsed.value;
    try out.print("loaded:   host={s} port={d} workers={d} debug={}\n", .{
        c.host, c.port, c.workers, c.debug,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Partial input: missing fields fall back to their defaults.
    try report(out, gpa,
        \\{ "host": "0.0.0.0", "port": 9000 }
    );

    // Empty input: entirely defaults.
    try report(out, gpa, "{}");

    // Well-formed JSON, bad value: caught by validate, not the parser.
    try report(out, gpa,
        \\{ "port": 80 }
    );

    // A typo'd field name is an error by default. It catches the config
    // the user *thought* they wrote.
    try report(out, gpa,
        \\{ "prot": 9000 }
    );

    // Not JSON at all.
    try report(out, gpa, "port = 9000");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.json-config`)*

## Walking the five cases

- **Partial input:** `host` and `port` come from the file, `workers` and
  `debug` from the defaults. This is the everyday path.
- **Empty input:** `{}` yields the all-defaults config. If that case errors,
  your defaults were never real.
- **Bad value:** `"port": 80` is perfectly valid JSON, so only `validate`
  can catch it. `error.PrivilegedPort` tells the user what to fix;
  `error.InvalidConfig` would not.
- **Typo'd field:** `"prot"` fails with `error.UnknownField` because
  rejecting unknown fields is the parser's default. Keep it: it catches the
  config the user *thought* they wrote. Opt out with
  `.ignore_unknown_fields = true` only when consuming payloads you don't
  fully model.
- **Not JSON:** the parser reports a syntax error; nothing was allocated to
  clean up.

## The errdefer is the subtle line

```zig
const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
errdefer parsed.deinit();
try validate(parsed.value);
return parsed;
```

`parsed` owns allocations (the `host` string, for one). If `validate` rejects
it, `load` returns an error and the caller never sees `parsed`, so nobody
else *can* free it. `errdefer` runs exactly on that path and only that path;
a plain `defer` would free the config on success too.

## Variations

- **Reading from disk:** feed `load` the result of
  `dir.readFileAlloc(io, path, gpa, limit)`. The parsing and validation
  don't change. (See the [Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/)
  chapter for the I/O side.)
- **Nested config:** struct fields can be structs, arrays, optionals, and
  enums; the parser maps JSON onto all of them, and enum fields give you
  "one of these strings" validation for free.
