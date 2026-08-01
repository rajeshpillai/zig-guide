//! title: cat
//! A loop around one fixed buffer, which is why it can copy a file larger than memory.

const std = @import("std");

/// The whole of `cat`. Fill a buffer, write exactly what was filled, repeat.
/// Nothing here knows how big the input is, and nothing needs to.
fn cat(in: *std.Io.Reader, out: *std.Io.Writer, buffer: []u8) !usize {
    var copied: usize = 0;
    while (true) {
        // A read returns what it has, not what you asked for. Treating the
        // return value as "the buffer is full now" is the oldest bug here,
        // and 0 is how the end announces itself rather than an error.
        const n = try in.readSliceShort(buffer);
        if (n == 0) return copied;
        try out.writeAll(buffer[0..n]);
        copied += n;
    }
}

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const input = "the quick brown fox\njumps over the lazy dog\n";

    // Four bytes at a time, to prove the size is a memory decision and not a
    // correctness one. Real cat uses something like 64 KB for the syscall
    // count, not because a smaller buffer would be wrong.
    var small: [4]u8 = undefined;
    var reader: std.Io.Reader = .fixed(input);
    const copied = try cat(&reader, out, &small);

    try out.print("\ncopied {d} bytes through a {d}-byte buffer\n", .{ copied, small.len });
    try out.flush();
}
