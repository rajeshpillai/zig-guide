//! title: The Environment
//! A string-to-string map the parent process chose, handed over at startup.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The real environment. The startup code parsed it into a map before
    // main. This program runs in a wasm sandbox that has no parent process.
    // Thus the count is the real value, not a placeholder.
    const env = init.environ_map;
    try out.print("inherited variables: {d}\n", .{env.count()});
    try out.print("PATH: {?s}\n\n", .{env.get("PATH")});

    // A put into the map does not change any other process. The map is the
    // copy that belongs to this program. A child gets a copy at spawn time.
    try env.put("ZIG_GUIDE", "live");
    try env.put("EDITOR", "vim");
    try out.print("after two puts: {d}\n", .{env.count()});
    try out.print("ZIG_GUIDE: {?s}\n", .{env.get("ZIG_GUIDE")});
    try out.print("contains EDITOR: {}\n", .{env.contains("EDITOR")});

    _ = env.swapRemove("EDITOR");
    try out.print("after removing it: {?s}\n\n", .{env.get("EDITOR")});

    // A name must not be empty and must not contain '='. You cannot escape
    // the separator. Thus you cannot read back a key that contains '='.
    try out.print("\"HOME\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("HOME")});
    try out.print("\"A=B\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("A=B")});

    try out.flush();
}
