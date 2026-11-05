# wc

> To count words, count each time that the input goes into a word.

To count bytes is trivial. To count lines is almost as easy: add one for each
`\n`. Words are more difficult, because a word is not a single byte in the
input. A word is a pattern *between* bytes.

If you try to count words directly, you need rules for many usual cases:

- Two spaces between words.
- A space at the start.
- A tab in place of a space.
- A line that ends without a newline.

If you handle each case as a special case, the code becomes complex, and soon
one case is wrong.

Instead, count **transitions**. Keep one bit that tells if the program is
inside a word now. Each time that bit changes from false to true, a word
starts. The difficult cases need no special code. A run of twelve spaces sets
the bit to false twelve times, and false is already false.

This one bit and the rule that changes it are a **state machine**, and a very
small one.

## The program

```zig
const std = @import("std");

const Counts = struct { lines: usize = 0, words: usize = 0, bytes: usize = 0 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

/// One pass, one byte at a time, one bit of state. `in_word` is the state
/// machine. The function counts a word when the input moves from a space into
/// a non-space. Thus runs of spaces cost nothing, and it reads each byte once.
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

/// Show the sample with its whitespace visible, so that you can check the counts.
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

Each sample tests one of the cases above.

**`"hello world\n"` and `"  hello   world  \n"` both give 2 words.** The byte
counts are different, 12 and 18, but the word count is the same. No code has
a special case for whitespace at the start or for repeated whitespace. The
transition never occurs two times in sequence, because the bit is already set.

**`"no newline at the end"` reports 0 lines and 5 words.** This is correct.
`wc` counts newline *characters*. Thus if the last line of a file has no
terminator, the file has one line fewer than you count with your eyes. Real
`wc` does exactly this. If `wc` reports "0 lines" for a file that clearly has
text in it, the file has no newline at the end.

**The empty input gives three zeroes** without special code, because a loop
over nothing runs zero times.

The counter never examines a byte two times, and it never needs the full input
in memory. Thus it works with the loop from the previous chapter:

1. Read one full buffer.
2. Send the buffer through the same state.
3. Do the steps again.

To count a file that is larger than memory, you need nothing new.

## Check yourself

Give this program the six-byte string `"héllo"`. How many words does it
report?

One. The `é` is two bytes, and neither byte is whitespace. Thus the program sets
the bit one time, and the bit stays set.

The word count is one of the few text operations that is correct on raw UTF-8
without knowledge of UTF-8. It only asks if a byte is one of six ASCII
whitespace values. UTF-8 makes sure that those bytes never appear inside a
multi-byte character.

An operation that needs *character* counts is a more difficult problem. That
problem is the subject of [Strings Are
Bytes](https://www.ziglang.in/learn/systems-from-scratch/strings-are-bytes/).

## If you know C

The C version has the same bit and the same loop:

```c
int in_word = 0;
for (...) {
    if (isspace(c)) in_word = 0;
    else if (!in_word) { in_word = 1; words++; }
}
```

In C, be careful with `isspace(c)` and a plain `char`. On a platform where
`char` is signed, a byte above 127 becomes negative. If you give `isspace` a
negative value that is not `EOF`, the result is undefined behaviour.

The fix is `isspace((unsigned char)c)`. Nobody can see this bug for years,
because it appears only on input that is not ASCII.

A `u8` in Zig cannot be negative, so the problem does not exist.

Next: [grep](https://www.ziglang.in/learn/unix-tools/grep/), where the program must answer a
question, and not only report on what it saw.
