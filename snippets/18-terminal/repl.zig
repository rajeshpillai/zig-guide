//! title: The Read-Eval-Print Loop
//! Four steps and two ways to stop. Programmers often get the stop wrong.

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
