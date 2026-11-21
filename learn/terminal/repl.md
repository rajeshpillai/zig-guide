# The Read-Eval-Print Loop

> Four steps and two ways to stop. Programmers often get the stop wrong.

Read a line. Find what the line means. Print the result. Return to the start.
Each shell, each database prompt and each language REPL runs this loop, and
the loop is four lines of code.

The end of the loop is less obvious. The loop can end in **two** ways, and the
two ways are completely different. A loop that handles only one of them has a
bug, and you can easily miss that bug before a release. The two ways are:

- The user asks the loop to stop: the user types `quit`.
- The input stops. On a terminal, the user presses Ctrl-D. In a pipeline, the
  input reaches the end of the file. This occurs each time a person writes
  `echo "help" | yourshell`.

A loop that looks only for `quit` runs forever at the first end of input. The
read continues to return an empty result, and an empty result is not `quit`.

## The program

```zig
const std = @import("std");

const Action = enum { printed, quit };

/// The "eval" half. It is separate from the loop, so that you can test it
/// without a terminal. For the same reason, this page can run the loop.
fn eval(line: []const u8, out: *std.Io.Writer) !Action {
    const trimmed = std.mem.trim(u8, line, " \t\r");

    if (trimmed.len == 0) return .printed; // a newline alone is not an error
    if (std.mem.eql(u8, trimmed, "quit")) return .quit;

    if (std.mem.startsWith(u8, trimmed, "echo ")) {
        try out.print("{s}\n", .{trimmed["echo ".len..]});
    } else if (std.mem.eql(u8, trimmed, "help")) {
        try out.writeAll("echo <text> | help | quit\n");
    } else {
        // Do not exit on unknown input. A REPL that exits on a typo is not
        // usable.
        try out.print("unknown command: {s}\n", .{trimmed});
    }
    return .printed;
}

/// The loop. It has two exits: the user asks to stop, or the input ends.
fn repl(input: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(input);

    while (true) {
        try out.writeAll("> ");

        // takeDelimiter returns null at the end of input (EOF). On a terminal,
        // the user presses Ctrl-D for EOF. A loop that checks only for "quit"
        // runs forever when a user presses Ctrl-D the first time.
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

**Two sessions, two exits.** The first session ended on `quit` and printed
`(bye)`. The second session came to the end of its input and printed
`(end of input)`. Both are normal ends, and neither is an error. The code paths
are different.

**The empty line did nothing and did not stop the loop.** When a user presses
Enter at a blank prompt, that is not a command and not an error. A REPL that
uses either of these two meanings annoys the user quickly.

**An unknown command printed a message, and the loop continued.** This is the
difference between a REPL and a batch program. A batch program usually stops
when it gets bad input. A REPL that exits on a typo is not usable. The input is
the same in both cases. The correct behavior depends on one question: does a
person wait at the prompt?

This page can run the loop because of the way the loop reads input. The loop
reads through a `std.Io.Reader`, and here the reader gets its bytes from a
string, not from a terminal. If you change the source of the bytes, the rest
of the loop stays the same. You test a REPL in the same way. Without this
method, a REPL is difficult to test.

## Check yourself

The demo prints `> ` and then echoes the line that it read. A real terminal
does not do that. Why not, and why must this demo do it?

A terminal echoes the characters while you type them. The characters appear
because the terminal driver shows them, not because the program printed them.
This page has no keyboard. The input is a string, and nothing shows that
string. When the demo echoes the line, the transcript is easy to read.

That difference is also important in real programs. A password prompt must
turn *off* the echo of the terminal before the read. That is a call to the
terminal driver, separate from the read. Thus a password read needs more than
a line read.

## If you know C

The loop is the same. C makes the end of the loop easy to get wrong:

```c
while (1) {
    write(1, "> ", 2);
    ssize_t n = read(0, buf, sizeof buf - 1);
    if (n <= 0) break;          /* forget this and Ctrl-D spins forever */
    buf[n] = '\0';
    ...
}
```

When `read` returns 0, the input is at its end, and that is not an error. A
check for only `n < 0` does not see the end, and the loop runs forever on an
empty read. Almost each programmer who writes a shell makes this mistake at
least one time.

The `sizeof buf - 1` is the same off-by-one as in the [strings
chapter](https://www.ziglang.in/learn/terminal/strings/). It keeps space for the terminator, because
`read` does not write the terminator.

## Where this section ends

This section has three primitives:

- Measure and copy text.
- Split a line into arguments.
- Loop until something stops the loop.

A shell needs these three primitives *before* it can run a program.

The next steps need a real kernel. Thus they are in the operating system
section, not here. One chapter starts a process. The chapter after it is about
pipes, where the output of one program becomes the input of another program.
Neither chapter can run on this page, and both chapters tell you this.
