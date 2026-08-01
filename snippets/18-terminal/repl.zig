//! title: The Read-Eval-Print Loop
//! Four steps and two ways to stop, which is the part people get wrong.

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
