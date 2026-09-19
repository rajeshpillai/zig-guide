# The Three Standard Streams

> Buffering belongs to your writer, not to the descriptor underneath it.

The output of the snippet below is not in the order the program wrote it.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two writers, both aimed at descriptor 1. One holds bytes back until it
    // is told to drain; the other has nowhere to hold them.
    var buf: [1024]u8 = undefined;
    var buffered = std.Io.File.stdout().writerStreaming(io, &buf);
    var unbuffered = std.Io.File.stdout().writerStreaming(io, &.{});

    try buffered.interface.writeAll("written first, into a buffer\n");
    try unbuffered.interface.writeAll("written second, straight to the fd\n");
    try buffered.interface.flush();

    const out = &buffered.interface;

    // Whether a stream is a terminal is a question about the descriptor, and
    // it is the question a program asks before deciding to emit colour. Under
    // a WASI sandbox, or a pipe, or a CI log file, the answer is no.
    try out.print("\nstdout is a tty: {}\n", .{try std.Io.File.stdout().isTty(io)});
    try out.print("stderr is a tty: {}\n", .{try std.Io.File.stderr().isTty(io)});

    // Descriptor 2 exists so that a diagnostic survives a redirect of the
    // program's output, and so that it is not sitting in a buffer when the
    // process dies. Progress, warnings and errors go here; results go to 1.
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

Both writers address descriptor 1. The first was given a 1 KB buffer and holds
bytes until it is drained. The second was given an empty slice and has nowhere
to put them, so each write goes out immediately. The second line reaches the
terminal first, and no amount of reading the source top to bottom would tell
you that.

The descriptor has no buffer. Buffering is something your writer does on your
side of the call, which is why the fix is `flush` and not a flag on the file.
[Hello, World](https://www.ziglang.in/learn/getting-started/hello-world/) covers the mechanics; the
point here is that two writers on one descriptor are two independent buffers
with no idea the other exists.

This is the single most common way interleaved output goes wrong. A program
prints progress to standard error unbuffered and results to standard output
buffered, and the log reads as though the work happened in an order it did
not.

## Which stream a line belongs on

Descriptor 1 is for what the program was asked to produce. Descriptor 2 is for
everything the program has to say about producing it.

The test is a pipe. `zig build 2>/dev/null | wc -l` should count results, not
warnings, and it only does if the split was made correctly. Anything a reader
would want to filter out of the data belongs on 2: progress, warnings, errors,
the name of the file being processed.

Standard error is also the stream that survives a crash. It is conventionally
unbuffered, or line buffered, for exactly that reason. A diagnostic still
sitting in a buffer when the process dies is a diagnostic you did not get, and
the process dying is when you wanted it most.

## `isTty`, and why anyone asks

```zig
std.Io.File.stdout().isTty(io)
```

The answer is false in the playground above, false in a CI log, false through
a pipe, and true in your terminal. It is a question about the descriptor, not
about the program. It is what a well-behaved tool asks before deciding to emit
colour escapes, redraw a progress bar in place, or print a table sized to the
window. A tool that skips the question writes escape sequences into the log
file someone will read next year.

## Both streams in the playground

The playground merges 1 and 2 into one pane, because a browser has one place
to put text. Under CI they stay separate. The runner routes each to its own
file and compares only standard output against the recorded expectation, which
is why the stderr line in this snippet is not in the expectation that gates
it. That is the right split for a test. What the program produced is the
contract; what it had to say while producing it is not.
