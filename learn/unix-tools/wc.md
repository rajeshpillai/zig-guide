# wc

> Counting words means counting the moments you enter one.

Counting bytes is trivial and counting lines is nearly so: add one for every
`\n`. Words are where it gets interesting, because a word is not a thing in
the input. It is a pattern *between* things.

Try to count words directly and you immediately need rules for cases the input
is full of. Two spaces between words. A leading space. A tab instead of a
space. A line that ends without a newline. Handle each as a special case and
you get a tangle that is wrong on the third one.

The trick is to stop counting words and count **transitions**. Keep one bit:
are we inside a word right now? Every time that bit goes from false to true, a
word has started. All the awkward cases stop being cases at all, because a run
of twelve spaces sets the bit to false twelve times and false is already
false.

That is a **state machine**, and it is the smallest useful one there is.

## The program

```zig
const std = @import("std");

const Counts = struct { lines: usize = 0, words: usize = 0, bytes: usize = 0 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

/// One pass, one byte at a time, one bit of state. `in_word` is the state
/// machine: a word is counted when the input crosses from space into non-space,
/// so runs of spaces cost nothing and the input is never looked at twice.
fn count(text: []const u8) Counts {
    var c: Counts = .{};
    var in_word = false;

    for (text) |ch| {
        c.bytes += 1;
        if (ch == '\n') c.lines += 1;

        if (isSpace(ch)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            c.words += 1;
        }
    }
    return c;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const samples = [_][]const u8{
        "hello world\n",
        "  hello   world  \n",
        "one\ntwo\nthree\n",
        "no newline at the end",
        "",
    };

    for (samples) |text| {
        const c = count(text);
        try out.print("{d:>3} {d:>3} {d:>3}  ", .{ c.lines, c.words, c.bytes });
        try printEscaped(out, text);
        try out.writeAll("\n");
    }

    try out.flush();
}

/// Show the sample with its whitespace visible, so the counts can be checked.
fn printEscaped(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeAll("\"");
    for (text) |ch| {
        if (ch == '\n') try out.writeAll("\\n") else try out.writeByte(ch);
    }
    try out.writeAll("\"");
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.wc`)*

## What just happened

The samples are chosen so the counts prove the claim.

**`"hello world\n"` and `"  hello   world  \n"` both give 2 words.** Different
byte counts, 12 against 18, and the same word count. Nothing in the code
special-cases leading or repeated whitespace; the transition never happens
twice in a row because the bit is already set.

**`"no newline at the end"` reports 0 lines and 5 words.** This is not a bug,
and it is worth sitting with. `wc` counts newline *characters*, so a file
whose last line has no terminator has one fewer line than you would count by
eye. Real `wc` does exactly this, and it is the reason a stray "0 lines" on a
file you can plainly see text in means the file has no trailing newline.

**The empty input gives three zeroes** without any special handling, because a
loop over nothing runs zero times.

The counter never looks at a byte twice and never needs the whole input in
memory. So it composes with the previous chapter: read a bufferful, feed it
through the same state, repeat. Counting a file larger than memory needs no
new ideas.

## Check yourself

If you fed this program the six-byte string `"héllo"`, how many words would it
report?

One. The `é` is two bytes, neither of which is whitespace, so the bit is set
once and stays set. Word counting is one of the few text operations that is
genuinely correct on raw UTF-8 without knowing anything about it. The only
thing it asks of a byte is whether it is one of six ASCII whitespace values,
and UTF-8 guarantees those bytes never appear inside a multi-byte character.
Anything that needs *character* counts is a harder problem, which is the
subject of [Strings Are
Bytes](https://www.ziglang.in/learn/systems-from-scratch/strings-are-bytes/).

## If you have written C

The C version is the same bit and the same loop:

```c
int in_word = 0;
for (...) {
    if (isspace(c)) in_word = 0;
    else if (!in_word) { in_word = 1; words++; }
}
```

The one thing to be careful of in C is `isspace(c)` with a plain `char`. On a
platform where `char` is signed, a byte above 127 becomes negative, and
passing a negative value that is not `EOF` to `isspace` is undefined
behaviour. The fix is `isspace((unsigned char)c)`, and it is the kind of bug
that survives for years because it only fires on non-ASCII input.

Zig's `u8` cannot be negative, so the question does not arise.

Next: [grep](https://www.ziglang.in/learn/unix-tools/grep/), where the program has to answer a
question rather than just report on what it saw.
