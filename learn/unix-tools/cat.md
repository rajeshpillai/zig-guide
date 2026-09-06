# cat

> A loop around one fixed buffer, which is why it can copy a file larger than memory.

`cat` copies its input to its output. That is the entire specification, and it
is the right place to start. The shape of this loop is the shape of every
program that moves bytes: a fixed buffer, a read that fills part of it, a
write of exactly that part, repeat.

The interesting question is the one the loop answers without ever asking it:
**how big is the input?** It never finds out. A program written this way copies a four-byte file and a four-gigabyte file
with the same code and the same memory. At no point does it hold more than one
bufferful.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.cat`)*

## What just happened

**The buffer is four bytes, and it still copied 44.** That number is there to
make the point unmissable: the buffer size is a decision about memory and
syscall count, not about correctness. Real `cat` uses something like 64 KB
because each read is a trip into the kernel and you want fewer of them, not
because a smaller one would be wrong.

**The read returns what it has, not what you asked for.** This is the sentence
to carry out of this chapter. `readSliceShort` fills *up to* the buffer and
tells you how many bytes it actually got. Treating that as "the buffer is full
now" is the oldest bug in this family of programs. You write the whole buffer,
including the stale bytes from last time, and the output has garbage in it. It
appears only under load, because only under load does a read come back short.

The same is true in the other direction, which is why the loop calls
`writeAll` rather than a single write. A write can be partial too.

**End of input is a zero, not an error.** There is nothing wrong with a file
ending, so it is not reported as a failure. The loop stops when a read returns
nothing.

## Check yourself

The program never checks whether the input contains text. Would it work on a
JPEG?

Yes, and unchanged. Nothing in the loop inspects a byte, so there is no notion
of a character, a line, or an encoding to get wrong. That is why `cat` on a
binary file scrambles your terminal rather than failing: the bytes arrive
intact, and the terminal is the thing interpreting them.

## If you have written C

Same loop, and the same two traps:

```c
char buf[4096];
ssize_t n;
while ((n = read(0, buf, sizeof buf)) > 0)
    write(1, buf, n);       /* n, never sizeof buf */
```

`read` returning fewer bytes than requested is normal, not an error. `write`
writing fewer than it was given is also normal, which is why the C version
needs its own loop around the write to be correct. Zig's `writeAll` is that
loop, already written.

The one thing C makes you do that Zig does not is check for `-1` and inspect
`errno`. Here a failure is an error in the return type, so `try` handles it
and there is no way to mistake `-1` for a byte count.

Next: [wc](https://www.ziglang.in/learn/unix-tools/wc/), which is the same loop with one bit of
memory added.
