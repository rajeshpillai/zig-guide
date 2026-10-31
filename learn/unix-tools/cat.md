# cat

> A loop around one fixed buffer. For this reason, cat can copy a file that is larger than memory.

`cat` copies its input to its output. That is the full specification, and it
is a good place to start.

Each program that moves bytes has the same loop:

1. Keep a fixed buffer.
2. Read into a part of the buffer.
3. Write exactly that part.
4. Do the steps again.

The loop never asks **how large is the input?** It never needs to know. A
program with this loop copies a four-byte file and a four-gigabyte file with
the same code and the same memory. At no time does the program hold more than
one full buffer.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.cat`)*

## What just happened

**The buffer is four bytes, and the program still copied 44.** The small
buffer shows that the size of the buffer does not change the correctness. The
size controls only the quantity of memory and the number of syscalls.

Real `cat` reads 128 KB at a time. Each read is a trip into the kernel, and
fewer trips are faster. A smaller buffer still gives the correct output.

**The read returns the bytes that it has, which can be fewer than you asked
for.** `readSliceShort` fills the buffer *up to* its size and tells you how
many bytes it actually got.

A common bug in programs like this one is to think that the buffer is now
full. Then you write the full buffer, with the old bytes from the last read,
and the output contains garbage. The bug appears only under load, because only
under load does a read return fewer bytes.

A write can also be partial. Thus the loop calls `writeAll`, not a single
write.

**End of input is a read that returns zero bytes.** The end of a file is not
a problem, so the reader does not report it as an error. The loop stops when
a read returns nothing.

## Check yourself

The program never checks if the input contains text. Does the program work on
a JPEG?

Yes, and without changes. No part of the loop examines a byte. Thus the loop
has no idea of a character, a line or an encoding that it can get wrong.

For the same reason, `cat` on a binary file makes your terminal show garbage,
and `cat` does not fail. The bytes arrive without changes. The terminal is the
part that tries to interpret them.

## If you know C

The loop is the same, and it has the same two traps:

```c
char buf[4096];
ssize_t n;
while ((n = read(0, buf, sizeof buf)) > 0)
    write(1, buf, n);       /* n, never sizeof buf */
```

It is normal for `read` to return fewer bytes than you requested. It is also
normal for `write` to write fewer bytes than you gave it. Thus a correct C
version needs its own loop around the write. The `writeAll` function of Zig is
that loop, already written.

C makes you check for `-1` and examine `errno`, but Zig does not. In Zig, a
failure is an error in the return type. Thus `try` handles the failure, and
you cannot confuse `-1` with a byte count.

Next: [wc](https://www.ziglang.in/learn/unix-tools/wc/). It is the same loop with one bit of memory
added.
