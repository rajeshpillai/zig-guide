//! title: The Environment
//! A string-to-string map the parent process chose, handed over at startup.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The real environment, already parsed into a map by the startup code.
    // This program is running in a wasm sandbox with no parent process to
    // inherit from, so the count is the honest answer rather than a stub.
    const env = init.environ_map;
    try out.print("inherited variables: {d}\n", .{env.count()});
    try out.print("PATH: {?s}\n\n", .{env.get("PATH")});

    // Putting a variable in the map does not change any other process. The
    // map is this program's copy; a child gets one when it is spawned.
    try env.put("ZIG_GUIDE", "live");
    try env.put("EDITOR", "vim");
    try out.print("after two puts: {d}\n", .{env.count()});
    try out.print("ZIG_GUIDE: {?s}\n", .{env.get("ZIG_GUIDE")});
    try out.print("contains EDITOR: {}\n", .{env.contains("EDITOR")});

    _ = env.swapRemove("EDITOR");
    try out.print("after removing it: {?s}\n\n", .{env.get("EDITOR")});

    // A name may not be empty and may not contain '='. The separator is not
    // escapable, so a key holding one could never be read back.
    try out.print("\"HOME\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("HOME")});
    try out.print("\"A=B\" valid: {}\n", .{std.process.Environ.Map.validateKeyForPut("A=B")});

    try out.flush();
}
