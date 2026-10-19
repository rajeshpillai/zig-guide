//! title: cat
//! A loop around one fixed buffer. Thus it can copy a file that is larger than memory.

const std = @import("std");

/// All of `cat`. Fill a buffer, write exactly the filled part, and do it again.
/// No line here knows the size of the input, and no line needs to know it.
fn cat(in: *std.Io.Reader, out: *std.Io.Writer, buffer: []u8) !usize {
    var copied: usize = 0;
    while (true) {
        // A read returns the bytes that it has, not the number that you asked
        // for. A common bug is to think that the buffer is now full.
        // A return of 0 means that the input ended. It is not an error.
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

    // Four bytes at a time. This shows that the size controls memory, not
    // correctness. Real cat uses 128 KB to make fewer syscalls. A smaller
    // buffer is not wrong.
    var small: [4]u8 = undefined;
    var reader: std.Io.Reader = .fixed(input);
    const copied = try cat(&reader, out, &small);

    try out.print("\ncopied {d} bytes through a {d}-byte buffer\n", .{ copied, small.len });
    try out.flush();
}
