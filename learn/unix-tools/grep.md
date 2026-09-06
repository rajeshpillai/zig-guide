# grep

> Search is a loop over start positions, and the exit code is the answer.

`grep` prints the lines that contain a pattern. Two things in it are worth
building by hand: the search itself, and the exit code, which is the part
people forget is a feature.

Substring search, done the obvious way, is two nested loops. Try the first
position: do the bytes match, one by one, until the pattern runs out? If the
pattern ran out, that is a match. If a byte disagreed, give up and try the next
starting position. That is O(n×m) in the worst case, and the worst case needs
input like `aaaaaaaaab` searched for `aaab`, which does not happen to a line of
text. There are cleverer algorithms, Boyer-Moore and friends, and they exist
because the naive one is genuinely good enough almost always.

## The program

```zig
const std = @import("std");

/// The naive search, written out rather than called, because it is the thing
/// worth seeing once: try every start position, compare forward, give up on
/// the first mismatch. O(n*m) in the worst case and fine for a line of text.
fn find(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len and haystack[start + i] == needle[i]) : (i += 1) {}
        if (i == needle.len) return start;
    }
    return null;
}

/// Returns whether anything matched, which is what the exit code reports.
/// grep's contract is that "found nothing" is not an error, and a shell
/// pipeline depends on being able to tell those two apart.
fn grep(text: []const u8, pattern: []const u8, out: *std.Io.Writer) !bool {
    var lines: std.Io.Reader = .fixed(text);
    var matched = false;
    var number: usize = 0;

    while (try lines.takeDelimiter('\n')) |line| {
        number += 1;
        if (find(line, pattern) != null) {
            matched = true;
            try out.print("{d}:{s}\n", .{ number, line });
        }
    }
    return matched;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const text =
        \\the quick brown fox
        \\jumps over the lazy dog
        \\the end
        \\
    ;

    for ([_][]const u8{ "the", "fox", "cat" }) |pattern| {
        try out.print("--- grep \"{s}\"\n", .{pattern});
        const matched = try grep(text, pattern, out);
        // 0 when something matched, 1 when nothing did. Not an error either way.
        try out.print("exit {d}\n\n", .{@intFromBool(!matched)});
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.grep`)*

## What just happened

**Three searches, and the third found nothing.** Look at what it printed:
`exit 1`. Not an error, not a message on stderr, just a different status.

This is the part that makes `grep` composable, and it is a design decision you
would not arrive at by thinking about searching. A shell needs to ask "does
this file mention the pattern" without caring about the output, and it does
that with `if grep -q pattern file; then`. For that to work, "found nothing"
has to be a *reportable outcome* rather than a failure. `grep` uses 0 for
found, 1 for not found, and 2 for an actual error like a missing file. Three
outcomes, one small integer, which is exactly the point made in
[Talking to the Operating System](https://www.ziglang.in/learn/systems-from-scratch/talking-to-the-os/).

**The line number came from counting, not from the search.** Nothing in the
input marks where line 2 starts. The loop over `takeDelimiter('\n')` counts as
it goes, which is the same streaming shape as the last two chapters.

**Matching is on bytes, and that is a real limitation.** Searching for `é`
works, because its two bytes are compared like any others. Searching
case-insensitively does not, because upper-casing a byte is only meaningful in
ASCII. Real `grep` with `-i` on UTF-8 has to know about Unicode case folding,
which is a much larger problem than the search.

## Check yourself

The search returns `?usize`, the position of a match, rather than `bool`. It
only ever gets compared against null here. Why not return `bool`?

Because the position is the thing a caller usually needs next, and it costs
nothing to return. `grep -o` prints just the matched part; `grep --color`
highlights it; a replace tool needs to know where to splice. Returning `bool`
throws away information the loop already had. This is a small instance of a
useful habit: return what you found, not merely that you found it.

## If you have written C

The search is the same, and C's standard library will do it for you:

```c
char *hit = strstr(line, pattern);   /* NULL when absent */
```

Two differences matter. `strstr` needs both strings null-terminated, so it
cannot search a slice of a larger buffer without you cutting it first, which
usually means copying. Zig's version takes lengths, so searching part of a
buffer is free.

And `strstr` returns a pointer *into* the haystack, which is a position and an
alias at the same time. Getting the index means `hit - line`, pointer
arithmetic that is only valid because both point into the same array.
Returning `?usize` says the same thing without the aliasing.

The standard library has this as `std.mem.find`, covered in
[String Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/). The version here is
written out because the loop is worth seeing once.

Next: [sort](https://www.ziglang.in/learn/unix-tools/sort/), the first tool that cannot stream.
