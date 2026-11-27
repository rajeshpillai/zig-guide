# Tokenize a Command Line

> Change "ls -la /tmp" into the argv that a shell needs, and copy nothing.

A shell reads a line and must change it into two things: a program to run, and
a list of arguments for that program. `execve` takes an array of strings. Thus
the line must become an array before the shell can do anything.

This chapter looks like the `cut` chapter, but the rule is the opposite. `cut`
splits a record on a delimiter, and two delimiters in a row mean an empty field.
A command line splits on *separation*, and two spaces in a row mean nothing.
`ls   -la` is two arguments, not four.

The rule is different because the meaning is different. In a data format, the
delimiter is structure. On a command line, the delimiter is whitespace.

## The program

```zig
const std = @import("std");

/// Split on runs of whitespace. The function returns slices of `line`. Thus
/// it copies nothing and allocates nothing. The result is valid only while
/// `line` is valid.
///
/// A run of spaces makes no empty argument. `cut` needs the opposite rule.
/// A command line is not a delimited record. The spaces only separate the
/// arguments. Thus `ls   -la` is two arguments.
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

    // A shell runs the first token with exec. It gives the other tokens to
    // that program as arguments.
    const args = try tokenize("grep -n main build.zig", &argv);
    try out.print("\ncommand: {s}\n", .{args[0]});
    for (args[1..], 1..) |arg, i| try out.print("  argv[{d}] = {s}\n", .{ i, arg });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`18-terminal.tokenize`)*

## What just happened

**`"  spaced   out   "` gave exactly two arguments.** Whitespace at the start, at
the end and in runs needs no extra code, because the loop has two phases:

1. Skip the whitespace.
2. Take all the bytes that are not whitespace.

Neither phase can make an empty token. Thus the code has no empty tokens to
handle.

Compare this loop with the [cut](https://www.ziglang.in/learn/unix-tools/cut/) chapter. In that
chapter, a loop that collapsed runs of delimiters was the bug. Both chapters
split a line of text. `cut` must keep the empty fields, and the tokenizer must
remove them, because the two inputs mean different things.

**An empty line and a line of only whitespace gave zero arguments.** A shell
needs this result. When you press Enter on an empty line, the shell must do
nothing. It must not try to run a program with an empty name. The loop handles
this case without a special check at the top, and the code for that is short.

**The program copied nothing.** Each argument is a slice of the line. The array
of slices is the argv that a shell gives to the next program, and the program
moved no bytes to make the array.

The cost is the usual cost of slices: the arguments are valid only while the
line buffer is valid. This cost is important when a shell must remember a
command for its history.

**The first token is the command.** It is not a special case. It is position
0. For this reason, `argv[0]` is the program name in each C program that you
wrote. The shell put the command there, and the convention stayed.

## Check yourself

This tokenizer splits `echo "hello world"` into three arguments. What does a
real shell do, and what does that mean for the loop?

A real shell gives two arguments: `echo` and `hello world`. Quotes add an
exception to the whitespace rule, and thus the loop needs state. Inside a quoted
run, whitespace is an ordinary character.

That state is one more bit, with the same shape as the bit that `wc` uses. With
that state, the tokenizer is not a simple split. It is a small parser.

Add escapes with backslashes, then variable expansion, then globs. Then the
"small parser" is most of a shell. At that point, a shell that you write from
zero must get a real lexer or remove support for quotes.

## If you know C

The C version tokenizes **in place**. This is the classic method:

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

The loop writes `\0` over each run of spaces. This changes one buffer into
several C strings, and the program can give them directly to `execve` with no
allocation.

The method is clever, but it destroys the input. The original line is gone.
Thus a shell that needs the line for its history must copy the line first.

Slices give the same result with zero allocations, and they do not change the
input. A slice can describe a part of a buffer, and it does not need a
terminator to mark the end. The line stays complete, and the tokens point into
the line.

The C version is better in one place: its tokens are already null-terminated
and ready for `execve`. For that boundary, Zig has `[:0]const u8` and [sentinel
termination](https://www.ziglang.in/learn/language-basics/sentinel-termination/). That chapter
explains the subject.

Next: [the read-eval-print loop](https://www.ziglang.in/learn/terminal/repl/). All of this code runs
inside that loop.
