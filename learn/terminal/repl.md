# The Read-Eval-Print Loop

> Four steps and two ways to stop, which is the part people get wrong.

Read a line. Work out what it means. Print the result. Go back to the start.
That is the loop every shell, every database prompt and every language REPL
runs, and it is four lines of code.

The part that is not obvious is how it ends. There are **two** ways, they are
completely different, and a loop that handles only one of them is broken in a
way that is easy to ship.

The first is the user asking: they type `quit`. The second is the input
running out. On a terminal that is Ctrl-D, and in a pipeline it is simply the
end of the file, which is what happens every single time somebody writes `echo
"help" | yourshell`. A loop that watches for `quit` and nothing else spins
forever the first time it meets end of input, because the read keeps returning
nothing and nothing is not `quit`.

## The program

```zig
const std = @import("std");

const Action = enum { printed, quit };

/// The "eval" half. Kept separate from the loop so it can be tested without a
/// terminal, which is also why this page can run at all.
fn eval(line: []const u8, out: *std.Io.Writer) !Action {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    if (trimmed.len == 0) return .printed; // a bare newline is not an error
    if (std.mem.eql(u8, trimmed, "quit")) return .quit;

    if (std.mem.startsWith(u8, trimmed, "echo ")) {
        try out.print("{s}\n", .{trimmed["echo ".len..]});
    } else if (std.mem.eql(u8, trimmed, "help")) {
        try out.writeAll("echo <text> | help | quit\n");
    } else {
        // Unknown input is not a reason to exit. A REPL that dies on a typo
        // is a REPL nobody uses.
        try out.print("unknown command: {s}\n", .{trimmed});
    }
    return .printed;
}

/// The loop. Two exits: the user asks to stop, or the input runs out.
fn repl(input: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(input);

    while (true) {
        try out.writeAll("> ");

        // takeDelimiter returns null at the end of input, which is EOF. On a
        // terminal that is Ctrl-D, and a loop that only checks for "quit"
        // spins forever the first time someone presses it.
        const line = try reader.takeDelimiter('\n') orelse {
            try out.writeAll("\n(end of input)\n");
            return;
        };

        try out.print("{s}\n", .{line});
        switch (try eval(line, out)) {
            .quit => {
                try out.writeAll("(bye)\n");
                return;
            },
            .printed => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    try out.writeAll("--- session that quits\n");
    try repl(
        \\help
        \\echo hello there
        \\
        \\nonsense
        \\quit
        \\
    , out);

    try out.writeAll("\n--- session that hits end of input\n");
    try repl("echo still here\n", out);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`18-terminal.repl`)*

## What just happened

**Two sessions, two exits.** The first ended on `quit` and printed `(bye)`. The
second ran out of input and printed `(end of input)`. Both are normal endings,
neither is an error, and the code paths are different.

**The empty line did nothing and did not stop the loop.** Pressing enter on a
blank prompt is not a command and not an error, and a REPL that treats it as
either is annoying within about four keystrokes.

**An unknown command printed a message and carried on.** This is the difference
between a REPL and a batch program. A batch program that meets bad input
should usually stop; a REPL that exits on a typo is unusable. Same input,
opposite correct behaviour, decided entirely by whether a human is waiting.

That is what makes this page possible at all. The loop takes a reader, so the
demo hands it a string instead of a terminal, and nothing in the loop knows
the difference. It is also how you test a REPL, which is otherwise one of the
more annoying things to test.

## Check yourself

The demo prints `> ` and then echoes the line it just read. A real terminal
does not do that. Why not, and why does this one have to?

Because a terminal echoes what you type as you type it: the characters appear
because the terminal driver puts them there, not because the program printed
them. This page has no keyboard, so the input is a string and nothing would
show it. Echoing the line makes the transcript readable.

That difference matters in real programs too. A password prompt has to turn
the terminal's echo *off* before reading. That is a call into the terminal
driver rather than anything to do with the read itself, and it is why reading
a password is not just reading a line.

## If you have written C

The loop is the same, and the ending is exactly where C makes it easy to get
wrong:

```c
while (1) {
    write(1, "> ", 2);
    ssize_t n = read(0, buf, sizeof buf - 1);
    if (n <= 0) break;          /* forget this and Ctrl-D spins forever */
    buf[n] = '\0';
    ...
}
```

`read` returning 0 is end of input, and it is not an error, so a check for `n
< 0` alone passes straight over it and loops forever on an empty read. That is
the bug this chapter exists to name, and it is a rite of passage for anyone
who has written a shell.

The `sizeof buf - 1` is the same off-by-one from the [strings
chapter](https://www.ziglang.in/learn/terminal/strings/), leaving room for the terminator that
`read` does not write.

## Where this section ends

Three primitives: measure and copy text, split a line into arguments, and loop
until something stops you. That is everything a shell needs *before* it can
run a program.

What comes next needs a real kernel, so it lives in the operating system
section rather than here. Spawning a process is one chapter, and pipes, where
the output of one program becomes the input of another, is the next. Neither
can run on this page, and both say so.
