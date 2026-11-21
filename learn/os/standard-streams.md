# The Three Standard Streams

> The buffer belongs to your writer, not to the descriptor under the writer.

The output of the snippet below is not in the order in which the program
wrote it.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two writers, both for descriptor 1. One holds bytes until the program
    // flushes it. The other has no buffer, so it writes the bytes at once.
    var buf: [1024]u8 = undefined;
    var buffered = std.Io.File.stdout().writerStreaming(io, &buf);
    var unbuffered = std.Io.File.stdout().writerStreaming(io, &.{});

    try buffered.interface.writeAll("written first, into a buffer\n");
    try unbuffered.interface.writeAll("written second, straight to the fd\n");
    try buffered.interface.flush();

    const out = &buffered.interface;

    // "Is the stream a terminal?" is a question about the descriptor. A
    // program asks it before it decides to write colour. Through a pipe, or
    // into a CI log file, the answer is no. The browser runner says yes.
    try out.print("\nstdout is a tty: {}\n", .{try std.Io.File.stdout().isTty(io)});
    try out.print("stderr is a tty: {}\n", .{try std.Io.File.stderr().isTty(io)});

    // Descriptor 2 exists for two reasons. A diagnostic stays visible when you
    // redirect the output of the program. Also, the diagnostic is not in a
    // buffer when the process stops. Progress, warnings and errors go here.
    // Results go to 1.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr\n");
    try err_writer.interface.flush();

    try out.writeAll("this line went to stdout\n");
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`14-os.standard-streams`)*

## Two writers, one descriptor

```zig
var buffered = std.Io.File.stdout().writerStreaming(io, &buf);
var unbuffered = std.Io.File.stdout().writerStreaming(io, &.{});

try buffered.interface.writeAll("written first, into a buffer\n");
try unbuffered.interface.writeAll("written second, straight to the fd\n");
try buffered.interface.flush();
```

Both writers write to descriptor 1:

- The first writer has a 1 KB buffer. It holds bytes until the program
  flushes the buffer.
- The second writer has an empty slice, so it has no place to keep bytes.
  Thus each write goes out immediately.

The second line gets to the terminal first. When you read the source from top
to bottom, you cannot see that.

The descriptor has no buffer. Your writer holds the buffer, on your side of
the call. Thus the fix is `flush`, not a flag on the file.
[Hello, World](https://www.ziglang.in/learn/getting-started/hello-world/) explains the mechanics.
Here, see this fact: two writers on one descriptor have two independent
buffers, and neither writer knows about the other.

Interleaved output often goes wrong in this way. A program prints progress to
standard error without a buffer, and it prints results to standard output with
a buffer. Then the log shows the work in an order that did not occur.

## Which stream a line belongs on

Descriptor 1 is for the output that the program must make. Descriptor 2 is for
all the messages that the program has about that work.

A pipe tests the split. `zig build 2>/dev/null | wc -l` must count results,
not warnings. It does this only if each line went to the correct stream.

Put on descriptor 2 all the text that a reader wants to remove from the data.
Examples are progress, warnings, errors, and the name of the file that the
program processes.

The output of standard error also stays after a crash. For this reason,
standard error usually has no buffer, or a line buffer. If a diagnostic is
still in a buffer when the process stops, you never see the diagnostic. After
a crash, you need the diagnostic most.

## `isTty`, and why programs ask it

```zig
std.Io.File.stdout().isTty(io)
```

The answer is true in the playground above, because the browser runner
reports both streams as a terminal. The answer is false in a CI log and
through a pipe. It is true in your terminal. The answer depends on the
descriptor, not on the program.

A good tool asks this question before it does one of these things:

- It writes colour escapes.
- It draws a progress bar again in the same place.
- It prints a table with the size of the window.

A tool that does not ask writes escape sequences into log files.

## Both streams in the playground

The playground puts 1 and 2 into one pane, because a browser has one place for
text. Under CI, the streams stay separate. The runner sends each stream to its
own file. It compares only standard output with the recorded expectation.

Thus the stderr line in this snippet is not in the expectation that gates the
snippet. That is the correct split for a test. The test checks what the
program made, and it ignores the messages that the program printed during the
work.
