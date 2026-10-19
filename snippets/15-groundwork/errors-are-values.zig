//! title: Errors Are Values
//! Failure is in the return type. Thus the caller cannot ignore it.

const std = @import("std");

/// The return type says two things: on success a u16, on failure one of a
/// known set of errors. A caller can see both, and does not have to read the
/// body.
fn parsePort(text: []const u8) !u16 {
    const value = try std.fmt.parseInt(u16, text, 10);
    if (value < 1024) return error.ReservedPort;
    return value;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const inputs = [_][]const u8{ "8080", "http", "99999", "80" };

    for (inputs) |text| {
        // `if` on a call that can fail separates the two cases. Neither branch
        // can see the value of the other branch. Thus you cannot read a result
        // that the function did not make.
        if (parsePort(text)) |port| {
            try out.print("{s: <6} -> port {d}\n", .{ text, port });
        } else |err| {
            // An error is an ordinary value. You can compare it, use it in a
            // switch, and pass it to other code, as any other value. This
            // switch has no `else` prong, because no other error can occur.
            // The compiler found the full set of errors that parsePort can
            // return. The compiler rejects an `else` prong as unreachable.
            const reason = switch (err) {
                error.InvalidCharacter => "not a number",
                error.Overflow => "too large for a u16",
                error.ReservedPort => "below 1024, needs privileges",
            };
            try out.print("{s: <6} -> {t}: {s}\n", .{ text, err, reason });
        }
    }

    // When a default is the correct answer, say so in one word. Do not write
    // a branch that only looks as if it handles the error.
    const port = parsePort("nonsense") catch 8080;
    try out.print("\nfalling back: {d}\n", .{port});

    try out.flush();
}
