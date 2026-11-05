# Recipe: Load a JSON Config

> Use defaults for absent fields, validate wrong values, and return clear errors for the other problems.

In Zig, `std.json.parseFromSlice` loads a JSON config into a struct. If the file does not have a field, and the field has a default value, the field keeps that default. Put checks such as a port range in a separate `validate` function, because the parser checks only types and field names.

## The problem

Your program reads a JSON config file, and users edit the file by hand. Thus each type of failure will occur:

- fields that are not in the file
- values that the parser accepts but that have no correct meaning
- field names with spelling errors
- files that are not JSON

For an absent field, the program must use a correct default. For a wrong value, the program must refuse the value with a *specific* error. The program must not crash, and it must not load only part of the config.

## The plan

1. **Put the defaults on the struct.** Give each field a default value. Then `std.json.parseFromSlice` sets only the fields that the input supplies. An empty `{}` is a complete and valid config.
2. **Validate in a separate step.** The parser checks the *shape*: the types and the field names. Your policy decides if `port: 80` is acceptable. Thus that check goes in a `validate` function with named errors.
3. **Use one `load` entry point** to connect the two steps. The function uses `errdefer`. Thus, if a config parses but fails validation, the function frees the config, and the config does not leak.

```zig
const std = @import("std");

const Config = struct {
    // Each field has a default. Thus an empty `{}` is a valid config.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    workers: u8 = 4,
    debug: bool = false,
};

// The parser checks the shape (types, field names). You must check the values.
fn validate(c: Config) error{ PrivilegedPort, TooManyWorkers }!void {
    if (c.port < 1024) return error.PrivilegedPort;
    if (c.workers == 0 or c.workers > 64) return error.TooManyWorkers;
}

fn load(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    // If validation refuses the config, the config must not leak.
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

    // Partial input: absent fields get their defaults.
    try report(out, gpa,
        \\{ "host": "0.0.0.0", "port": 9000 }
    );

    // Empty input: all fields get their defaults.
    try report(out, gpa, "{}");

    // Valid JSON with a bad value: validate finds the error, not the parser.
    try report(out, gpa,
        \\{ "port": 80 }
    );

    // By default, a field name with a spelling error is an error. It finds a
    // config that is different from the config that the user *wanted*.
    try report(out, gpa,
        \\{ "prot": 9000 }
    );

    // The text is not JSON.
    try report(out, gpa, "port = 9000");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.json-config`)*

## The five cases

- **Partial input:** `host` and `port` come from the file. `workers` and `debug` come from the defaults. This is the usual path.
- **Empty input:** `{}` gives the config with all defaults. If this case gives an error, a field does not have a default.
- **Bad value:** `"port": 80` is valid JSON. Thus only `validate` can find the problem. `error.PrivilegedPort` tells the user what to repair. `error.InvalidConfig` does not.
- **A field name with a spelling error:** `"prot"` fails with `error.UnknownField`, because by default the parser refuses unknown fields. Keep that default. It finds a field that the user wanted to set but spelled incorrectly. Use `.ignore_unknown_fields = true` only for payloads that your struct does not fully model.
- **Not JSON:** the parser reports a syntax error. The parser allocated no memory. Thus the program has no memory to free.

## The errdefer is the important line

```zig
const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
errdefer parsed.deinit();
try validate(parsed.value);
return parsed;
```

`parsed` owns allocations, for example the `host` string. If `validate` refuses the config, `load` returns an error. Then the caller does not get `parsed`, thus no other code *can* free it.

`errdefer` runs on that path, and on no other path. A plain `defer` also frees the config when `load` succeeds.

## Variations

- **Read from disk:** give `load` the result of `dir.readFileAlloc(io, path, gpa, limit)`. The parse and the validation do not change. (The [Filesystem](https://www.ziglang.in/learn/standard-library/filesystem/) chapter shows the I/O part.)
- **Nested config:** a struct field can be a struct, an array, an optional or an enum. The parser maps JSON onto all of these types. An enum field also checks that the value is one of a set of strings, with no more code.
