# grep

> Search is a loop over start positions, and the exit code is the answer.

`grep` prints the lines that contain a pattern. This chapter builds two parts
of `grep` by hand: the search, and the exit code. The exit code is also a
feature, and people often forget it.

The obvious substring search is two nested loops:

1. Go to the first position.
2. Compare the bytes one by one, until the pattern ends.
3. If the pattern ended, that is a match.
4. If a byte is different, stop and go to the next start position.

In the worst case, the search is O(n×m). The worst case needs input like
`aaaaaaaaab` with the pattern `aaab`, and a normal line of text does not
look like that. There are faster algorithms, for example Boyer-Moore. Here,
they are less important than you possibly expect, because the simple search is
fast enough on a line of text.

## The program

```zig
const std = @import("std");

/// The simple search, written out here, so that you can see it one time.
/// Try each start position, compare forward, and stop at the first mismatch.
/// O(n*m) in the worst case, and good enough for a line of text.
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

/// Returns true if a line matched. The exit code reports this result.
/// The contract of grep is that "found nothing" is not an error. A shell
/// pipeline must see the difference between those two results.
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
        // 0 when a line matched, 1 when no line matched. Neither is an error.
        try out.print("exit {d}\n\n", .{@intFromBool(!matched)});
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.grep`)*

## What just happened

**The program did three searches, and the third search found nothing.** Look
at the output: `exit 1`. The program printed no error and nothing on stderr.
Only the exit status changed.

With the exit status, other programs can use `grep`. If you think only about
the search, you do not think of this design. A shell must ask "does this file
contain the pattern?", and the shell does not need the output. The shell asks
with `if grep -q pattern file; then`.

For this to work, "found nothing" must be a *result that grep can report*,
not a failure. `grep` uses three values:

- 0 when it found a match.
- 1 when it found no match.
- 2 for a real error, for example a file that does not exist.

One small integer carries all three results, as
[Talk to the Operating System](https://www.ziglang.in/learn/systems-from-scratch/talking-to-the-os/)
describes.

**The program counted to get the line number.** The search does not know the
line number. Nothing in the input marks the start of line 2. The loop over
`takeDelimiter('\n')` counts each line. It is the same streaming loop as in the
last two chapters.

**The match compares bytes, and this has a limit.** A search for `é` works,
because the program compares its two bytes like all other bytes. A search
that ignores case does not work. A change to upper case is correct for a byte
only in ASCII. With `-i` on UTF-8, real `grep` must know Unicode case folding,
which is a much larger problem than the search.

## Check yourself

The search returns `?usize`, the position of a match, not `bool`. Here, the
program only compares the result with null. Why not return `bool`?

Usually, a caller needs the position next, and to return the position costs
nothing. `grep -o` prints only the part that matched. `grep --color`
highlights that part. A replace tool must know where to splice.

If the function returns `bool`, it discards information that the loop already
had. As a habit, return the position of what you found, not only a yes or no.

## If you know C

The search is the same, and the C standard library can do it for you:

```c
char *hit = strstr(line, pattern);   /* NULL when absent */
```

Two differences are important. First, `strstr` needs two null-terminated
strings. Thus `strstr` cannot search a slice of a larger buffer until you cut
the slice, and usually that means a copy. The Zig version takes lengths, so a
search of a part of a buffer needs no copy.

Second, `strstr` returns a pointer *into* the haystack. That pointer is a
position and an alias at the same time. To get the index, you write
`hit - line`. This pointer arithmetic is valid only because both pointers
point into the same array. A `?usize` gives the same information without the
alias.

The standard library has this function as `std.mem.find`.
[String Recipes](https://www.ziglang.in/learn/standard-library/string-recipes/) covers it. This
chapter writes out the function, so that you can see the loop.

Next: [sort](https://www.ziglang.in/learn/unix-tools/sort/), the first tool that cannot stream.
