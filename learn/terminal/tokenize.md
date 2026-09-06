# Tokenizing a Command Line

> Turning "ls -la /tmp" into the argv a shell needs, without copying anything.

A shell reads a line and has to turn it into two things: a program to run, and
a list of arguments to hand it. `execve` takes an array of strings, so the
line has to become an array before anything can happen.

That sounds like the `cut` chapter, and it is the opposite. `cut` splits a
record on a delimiter, where two delimiters in a row mean an empty field. A
command line splits on *separation*, where two spaces in a row mean nothing at
all. `ls   -la` is two arguments, not four.

The rule is different because the meaning is different: in a data format the
delimiter is structure, and on a command line it is whitespace.

## The program

```zig
const std = @import("std");

/// Split on runs of whitespace. Returns slices of `line`, so nothing is
/// copied and nothing is allocated, and the result is only valid while `line`
/// is.
///
/// A run of spaces produces no empty argument, which is the opposite of the
/// rule `cut` needs. A command line is not a delimited record: the delimiter
/// is separation, not structure, so `ls   -la` is two arguments.
fn tokenize(line: []const u8, out: [][]const u8) ![][]const u8 {
    var n: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and isSpace(line[i])) i += 1;
        if (i == line.len) break;

        const start = i;
        while (i < line.len and !isSpace(line[i])) i += 1;

        if (n == out.len) return error.TooManyArguments;
        out[n] = line[start..i];
        n += 1;
    }
    return out[0..n];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var argv: [8][]const u8 = undefined;

    const lines = [_][]const u8{
        "ls -la /tmp",
        "  spaced   out   ",
        "single",
        "",
        "   ",
    };

    for (lines) |line| {
        const args = try tokenize(line, &argv);
        try out.print("\"{s}\"\n  {d} args:", .{ line, args.len });
        for (args) |arg| try out.print(" [{s}]", .{arg});
        try out.writeAll("\n");
    }

    // The first token is what a shell would exec; the rest are handed to it.
    const args = try tokenize("grep -n main build.zig", &argv);
    try out.print("\ncommand: {s}\n", .{args[0]});
    for (args[1..], 1..) |arg, i| try out.print("  argv[{d}] = {s}\n", .{ i, arg });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`18-terminal.tokenize`)*

## What just happened

**`"  spaced   out   "` gave exactly two arguments.** Leading, trailing and
repeated whitespace all cost nothing, because the loop has two phases: skip
whitespace, then take everything that is not whitespace. Neither phase can
produce an empty token, so the awkward cases never arise.

Compare that to the [cut](https://www.ziglang.in/learn/unix-tools/cut/) chapter, where collapsing
runs of delimiters was the bug. Same operation, opposite rule, and the reason
is the meaning of the input rather than anything about splitting.

**Empty and whitespace-only lines gave zero arguments.** That is what a shell
needs: pressing enter on an empty line should do nothing, not try to run a
program with an empty name. Getting this to fall out of the loop rather than
being a special case at the top is worth the thirty seconds it takes.

**Nothing was copied.** Every argument is a slice of the line. The array of
slices is the argv a shell would pass on, and building it moved no bytes. The
cost is the usual one: the arguments are only valid while the line buffer is,
which matters the moment a shell wants to remember a command for its history.

**The first token is the command.** Not a special case, just position 0. That
is why `argv[0]` is the program name in every C program you have written: the
shell put the command there and the convention stuck.

## Check yourself

This tokenizer would split `echo "hello world"` into three arguments. What
would a real shell do, and what does that mean for the loop?

A real shell gives two: `echo` and `hello world`. Quoting means the whitespace
rule has an exception, which means the loop needs state: inside a quoted run,
whitespace is an ordinary character. That is one more bit of state, the same
shape as the one `wc` uses. It is where the tokenizer stops being a split and
starts being a small parser.

Add escaping with backslashes, then variable expansion, then globbing, and the
"small parser" is most of a shell. This is the point where every from-scratch
shell either grows a real lexer or quietly decides not to support quoting.

## If you have written C

The C version tokenizes **in place**, which is the classic trick:

```c
char *argv[8];
int argc = 0;
char *p = line;
while (*p) {
    while (*p == ' ') *p++ = '\0';    /* overwrite separators with terminators */
    if (*p) argv[argc++] = p;
    while (*p && *p != ' ') p++;
}
```

Writing `\0` over each run of spaces turns one buffer into several C strings
that can be passed straight to `execve`, with no allocation. It is genuinely
clever and it destroys the input: the original line is gone, so a shell that
wants it for history has to have copied it first.

Slices give the same zero-allocation result without the destruction, because a
slice can describe a piece of a buffer without needing a terminator to mark
where it stops. The line stays intact and the tokens point into it.

The one place C's version wins is that its tokens are already null-terminated
and ready for `execve`. Zig has `[:0]const u8` and [sentinel
termination](https://www.ziglang.in/learn/language-basics/sentinel-termination/) for that boundary,
which is the subject of its own chapter.

Next: [the read-eval-print loop](https://www.ziglang.in/learn/terminal/repl/), which is the loop all
of this sits inside.
