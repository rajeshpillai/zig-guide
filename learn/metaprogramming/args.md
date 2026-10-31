# Project: Parse Arguments from a Struct

> The fields of a struct are the options. The compiler makes the parser and the help text.

A command-line program declares its options in one place and parses them in another. When you add an option, you must change both places, and the help text too. If you forget one, the three disagree.

In this project, a struct is the only declaration. The compiler reads the fields of the struct and makes the parser and the help text from them. A new field is a new option, with no other change.

The project uses [Read a Type](https://www.ziglang.in/learn/metaprogramming/read-a-type/) for the fields and their defaults. [Command-Line Arguments](https://www.ziglang.in/learn/standard-library/command-line/) shows how a real program gets its arguments. This page uses a fixed list of strings, so that the program can run in your browser.

```zig
const std = @import("std");

const Level = enum { debug, info, warn };

// Each field is one option. A field with a default is optional.
const Options = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
    verbose: bool = false,
    level: Level = .info,
    name: []const u8,
};

const ParseError = error{ UnknownOption, MissingValue, BadValue, MissingOption };

fn parseValue(comptime T: type, text: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch error.BadValue,
        .@"enum" => std.meta.stringToEnum(T, text) orelse error.BadValue,
        .pointer => if (T == []const u8) text else @compileError("unsupported option type " ++ @typeName(T)),
        else => @compileError("unsupported option type " ++ @typeName(T)),
    };
}

fn parse(comptime T: type, args: []const []const u8) ParseError!T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    // One flag for each field: did an argument set it?
    var seen: [info.field_names.len]bool = @splat(false);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        const key = arg[2..];
        var known = false;
        // The compiler unrolls this loop: one `if` for each field.
        inline for (info.field_names, info.field_types, 0..) |name, F, f| {
            if (std.mem.eql(u8, key, name)) {
                known = true;
                seen[f] = true;
                if (F == bool) {
                    @field(result, name) = true;
                } else {
                    i += 1;
                    if (i == args.len) return error.MissingValue;
                    @field(result, name) = try parseValue(F, args[i]);
                }
            }
        }
        if (!known) return error.UnknownOption;
    }

    // A field that no argument set gets its default, or is an error.
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, f| {
        if (!seen[f]) {
            @field(result, name) = attrs.defaultValue(F) orelse return error.MissingOption;
        }
    }
    return result;
}

// The help text, made during compilation from the same struct.
fn help(comptime T: type) []const u8 {
    comptime var text: []const u8 = "options:\n";
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const kind = switch (@typeInfo(F)) {
            .bool => "",
            .@"enum" => |e| blk: {
                var choices: []const u8 = "";
                for (e.field_names, 0..) |choice, c| choices = choices ++ (if (c == 0) "" else "|") ++ choice;
                break :blk " <" ++ choices ++ ">";
            },
            else => if (F == []const u8) " <text>" else " <" ++ @typeName(F) ++ ">",
        };
        const required = if (attrs.defaultValue(F) == null) " (required)" else "";
        text = text ++ "  --" ++ name ++ kind ++ required ++ "\n";
    }
    return text;
}

fn show(out: *std.Io.Writer, args: []const []const u8) !void {
    try out.print("args:", .{});
    for (args) |arg| try out.print(" {s}", .{arg});
    try out.print("\n", .{});
    if (parse(Options, args)) |o| {
        try out.print("  port={d} host={s} verbose={} level={t} name={s}\n", .{ o.port, o.host, o.verbose, o.level, o.name });
    } else |err| {
        try out.print("  error: {t}\n", .{err});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("{s}", .{comptime help(Options)});
    try show(out, &.{ "--name", "api" });
    try show(out, &.{ "--name", "api", "--port", "9090", "--verbose", "--level", "debug" });
    try show(out, &.{"--port"});
    try show(out, &.{ "--port", "99999", "--name", "x" });
    try show(out, &.{ "--level", "loud", "--name", "x" });
    try show(out, &.{ "--colour", "red" });
    try show(out, &.{"--verbose"});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`25-comptime.args`)*

## The options are a struct

```zig
const Options = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
    verbose: bool = false,
    level: Level = .info,
    name: []const u8,
};
```

The parser uses these rules:

- The name of a field is the name of an option: `port` is `--port`.
- A `bool` field is a flag. `--verbose` sets it to `true`, and it takes no value.
- Each other field takes the next argument as its value.
- A field with a default is optional. A field without a default must get a value from an argument.

## The help text

```
options:
  --port <u16>
  --host <text>
  --verbose
  --level <debug|info|warn>
  --name <text> (required)
```

`help` walks the fields during compilation and joins the lines with `++`. For an enum field, it lists the tag names from `@typeInfo`. The `main` function prints the text with `comptime help(Options)`, thus the binary contains the finished text.

## Match an argument to a field

```zig
inline for (info.field_names, info.field_types, 0..) |name, F, f| {
    if (std.mem.eql(u8, key, name)) {
        known = true;
        seen[f] = true;
        if (F == bool) {
            @field(result, name) = true;
        } else {
            i += 1;
            if (i == args.len) return error.MissingValue;
            @field(result, name) = try parseValue(F, args[i]);
        }
    }
}
```

`key` is a runtime string. The `inline for` makes one `if` for each field, and each `if` compares `key` with one comptime-known name. In each copy, `F` is a known type. Thus the `F == bool` test disappears, and each copy contains only one of the two branches.

`parseValue` has one branch for each kind of type: an integer, an enum or a string. A field of another type, for example an `f32`, stops the build with `unsupported option type f32`.

## Defaults and required options

```zig
inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, f| {
    if (!seen[f]) {
        @field(result, name) = attrs.defaultValue(F) orelse return error.MissingOption;
    }
}
```

`seen` has one `bool` for each field. After the arguments, each field that no argument set gets its default value. A field with no default gives `error.MissingOption`.

## The results

```
args: --name api
  port=8080 host=localhost verbose=false level=info name=api
args: --name api --port 9090 --verbose --level debug
  port=9090 host=localhost verbose=true level=debug name=api
args: --port
  error: MissingValue
args: --port 99999 --name x
  error: BadValue
args: --level loud --name x
  error: BadValue
args: --colour red
  error: UnknownOption
args: --verbose
  error: MissingOption
```

`99999` does not fit in a `u16`, thus `parseInt` fails, and the parser returns `error.BadValue`. `loud` is not a tag of `Level`. The last list does not set `--name`, and `name` has no default.

## Limits of this parser

- An option can occur two times. The second value replaces the first.
- There are no short names such as `-v`. A short name needs a second name for a field. One method is a declaration in the struct, for example `pub const short = .{ .verbose = 'v' };`, which `@hasDecl` can find.
- The errors do not say which option failed. A real parser returns a diagnostic with the argument, as well as the error.

## Check yourself

Add the field `threads: u8 = 4` to `Options`. Which parts of the program must change?

None. The help text gets the line `--threads <u8>`, and the parser accepts `--threads 8`. If no argument sets it, `threads` gets its default, 4. `parseValue` already handles each integer type.
