//! title: Errors Are Values
//! Failure is in the return type, so the caller cannot walk past it.

const std = @import("std");

/// The return type says two things: on success a u16, on failure one of a
/// known set of errors. A caller can see both without reading the body.
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
        // `if` on a call that can fail splits the two cases apart. Neither
        // branch can see the other's value, so there is no way to read a
        // result that was never produced.
        if (parsePort(text)) |port| {
            try out.print("{s: <6} -> port {d}\n", .{ text, port });
        } else |err| {
            // An error is an ordinary value. It can be compared, switched on,
            // and passed around like any other. There is no `else` prong here
            // because there is nothing left to catch: the compiler worked out
            // the complete set of errors parsePort can return, and adding an
            // `else` would be rejected as unreachable.
            const reason = switch (err) {
                error.InvalidCharacter => "not a number",
                error.Overflow => "too large for a u16",
                error.ReservedPort => "below 1024, needs privileges",
            };
            try out.print("{s: <6} -> {t}: {s}\n", .{ text, err, reason });
        }
    }

    // When a default is genuinely correct, say so in one word rather than
    // writing a branch that pretends to handle it.
    const port = parsePort("nonsense") catch 8080;
    try out.print("\nfalling back: {d}\n", .{port});

    try out.flush();
}
