# Command-Line Arguments

> Reading argv and the environment through std.process.

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "iterate arguments" {
    const gpa = std.testing.allocator;
    // A real program iterates `init.minimal.args` (see the page). Here we
    // parse a fixed command line with the same iterator, so the test stays
    // deterministic in the browser sandbox, which has no argv of its own.
    var it = try std.process.Args.IteratorGeneral(.{}).init(gpa, "app --name zig -v");
    defer it.deinit();

    try expectEqualStrings("app", it.next().?); // argv[0] is the program name
    try expectEqualStrings("--name", it.next().?);
    try expectEqualStrings("zig", it.next().?);
    try expectEqualStrings("-v", it.next().?);
    try expect(it.next() == null); // exhausted
}

test "a minimal flag parser" {
    const gpa = std.testing.allocator;
    var it = try std.process.Args.IteratorGeneral(.{}).init(gpa, "app --verbose --out result.txt");
    defer it.deinit();

    _ = it.next(); // skip argv[0]
    var verbose = false;
    var out: []const u8 = "a.out";
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            // A flag that takes a value pulls the next token itself.
            out = it.next() orelse return error.MissingValue;
        }
    }
    try expect(verbose);
    try expectEqualStrings("result.txt", out);
}

test "environment variables" {
    const gpa = std.testing.allocator;
    // `init.environ_map` is exactly this type, filled from the real
    // environment. Building one by hand keeps the test self-contained.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("EDITOR", "vim");

    try expectEqualStrings("vim", env.get("EDITOR").?);
    try expect(env.get("MISSING") == null);
    try expect(env.contains("EDITOR"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.command-line`)*

## Where the real arguments come from

Your `main` receives a `std.process.Init` (the same value that carries `io`,
`gpa`, and the arena). Its `minimal.args` field is a `std.process.Args`, and
`iterate` turns it into an iterator whose `next` yields each argument as a
`[:0]const u8`:

```zig
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    defer it.deinit();

    _ = it.next(); // argv[0]: the program's own path
    while (it.next()) |arg| {
        // ... handle arg ...
    }
}
```

The snippet above uses `Args.IteratorGeneral`, which parses a fixed string
with the identical `next` shape. That is what lets it run in your browser: the
WASI sandbox has no argv of its own, so a real iterator would come back empty.
The parsing logic you write is the same either way.

## Parsing is yours to write

There is no `argparse` in the standard library. For a small tool the loop in
the snippet, match a flag, and pull the next token when it takes a value, is
usually all you need. The first argument is always the program path, so skip
it before parsing. Reach for a package (see the Build System section) only
when you want subcommands, help text, and typed conversion.

## Environment variables

`init.environ_map` is a `std.process.Environ.Map` built from the real
environment. It behaves like the other maps in this section: `get` returns an
optional, `contains` a bool. Because absence is normal for an environment
variable, `get` returning `null` is the case you handle, not an error.

## Spawning other programs

The reverse direction, running a subprocess, is `std.process.Child`. Like
everything that touches the outside world it takes an `Io`, and it lets you
wire up the child's stdin, stdout, and stderr or capture its output. It needs
a real OS process, so it is not something the browser sandbox can demonstrate.

## Conventions worth following

There is no parser in `std`, so the conventions are yours to honour, and users
expect them:

- `-v` is a short flag, `--verbose` is its long form, and both should work.
- `--output=file` and `--output file` are both common. Accepting only one
  annoys somebody.
- Combined short flags, `-abc` meaning `-a -b -c`, are expected of anything
  resembling a Unix tool.
- `--` ends the options. Everything after it is a positional argument even if it
  starts with a dash, which is the only way to name a file called `-r`.
- `-` on its own conventionally means standard input, not a file.

None of this is hard, and all of it is easy to leave out. Deciding up front
which of these you support is better than discovering the gap from a bug
report.

## Failing well

A command-line program's error handling is its user interface. Three rules
cover most of it.

Write errors to stderr, not stdout. Anything that might be piped into another
program has to keep its output stream clean. A diagnostic mixed into the data
becomes a bug in a shell pipeline that is hard to find.

Exit non-zero on failure. Returning an error from `main` does that for you and
prints the error name plus a return trace in a debug build. When you want a
specific status, `std.process.exit(2)` sets one, and the convention is 0 for
success, 1 for a normal failure, 2 for a usage error.

Say what was wrong and what to do about it. "invalid argument" is a worse
message than "unknown option --outpt (did you mean --output?)", and the
difference is a few lines in the loop that already knows which token failed.

## Arguments are untrusted input

Everything on the command line came from outside the program. A number is a
`parseInt` that can fail, a path may not exist, a count may be enormous. Check
the value where it enters, and convert it into a type that carries the
constraint. The rest of the program then deals with a `u16` port rather than a
string somebody typed. See [parsing and
encoding](https://www.ziglang.in/learn/standard-library/parsing-and-encoding/).
