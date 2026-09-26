# String Primitives

> strlen, compare, copy and trim, written out. This is where the off-by-one error happens.

Nothing else in this track can be built until text can be measured, compared,
copied and trimmed. Everything else depends on those four operations. Writing them out once
teaches more than reading about them, because three of the four contain a
well-known mistake.

## The program

```zig
const std = @import("std");

/// Walk until the zero. This is the function C calls `strlen`, and its cost is
/// the reason a slice carries its length instead: this is O(n) every time you
/// ask, and code that asks inside a loop turns an O(n) job into O(n^2).
fn strLen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Copy `src` into `dest` and terminate it. Returns null when it will not fit,
/// instead of writing part of it.
///
/// The `+ 1` is for the terminator. A 5-byte string needs 6 bytes of room, and
/// the version of this that checks `src.len > dest.len` compiles, passes a
/// casual test, and writes one byte past the end of the buffer.
fn strCopy(dest: []u8, src: []const u8) ?[:0]u8 {
    if (src.len + 1 > dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Both ends, without moving anything. Trimming does not need a copy: the
/// answer is a slice of the bytes you already have.
fn strTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isSpace(s[start])) start += 1;
    while (end > start and isSpace(s[end - 1])) end -= 1;
    return s[start..end];
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const greeting = "hello";
    try out.print("strLen(\"hello\")   = {d}\n", .{strLen(greeting)});
    try out.print("greeting.len      = {d}   (already known, no walk)\n\n", .{greeting.len});

    try out.print("strEq(\"cat\",\"cat\") = {}\n", .{strEq("cat", "cat")});
    try out.print("strEq(\"cat\",\"cot\") = {}\n", .{strEq("cat", "cot")});
    try out.print("strEq(\"cat\",\"cats\")= {}\n\n", .{strEq("cat", "cats")});

    // Six bytes of room for five bytes of text.
    var room: [6]u8 = undefined;
    if (strCopy(&room, "hello")) |copied| {
        try out.print("copied \"{s}\" into 6 bytes, terminator at index {d}\n", .{ copied, copied.len });
    }
    var tight: [5]u8 = undefined;
    try out.print("copying \"hello\" into 5 bytes -> {s}\n\n", .{
        if (strCopy(&tight, "hello") == null) "refused" else "wrote",
    });

    // Its own buffer. Passing `buf` here aliased the writer's own storage and
    // the first line of output came out garbled. Both slices carry a length,
    // so the mistake garbled the output instead of writing past a buffer.
    var scratch: [64]u8 = undefined;
    for ([_][]const u8{ "  padded  ", "\tboth\n", "none", "   ", "" }) |sample| {
        try out.print("trim(\"{s}\") -> \"{s}\"\n", .{ escape(sample, &scratch), strTrim(sample) });
    }

    try out.flush();
}

/// Render whitespace visibly so the trimming can be checked by eye.
fn escape(s: []const u8, scratch: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        const replacement: []const u8 = switch (c) {
            '\t' => "\\t",
            '\n' => "\\n",
            else => &[_]u8{c},
        };
        @memcpy(scratch[n..][0..replacement.len], replacement);
        n += replacement.len;
    }
    return scratch[0..n];
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`18-terminal.strings`)*

## What just happened

**`strLen` walks, and `.len` does not.** Both printed 5. One of them counted
bytes until it found a zero; the other read a number that was already there.
On a five-byte greeting the difference costs almost nothing. In a loop it can
cost a lot:

```c
for (int i = 0; i < strlen(s); i++)   /* walks the string on every iteration */
```

That is an O(n) job written as O(n²). It is a common performance
bug in C, and it cannot be written at all with a slice, because there is no
call to accidentally repeat.

**`strEq` checks the length first.** Comparing contents when the lengths differ
is wasted work. More importantly, a loop that skips the length check would read
past the end of the shorter string. `"cat"` against `"cats"` is false in one
comparison.

**The copy refused instead of truncating.** Six bytes of room took `"hello"`;
five bytes did not. The check is `src.len + 1 > dest.len`. The `+ 1` is
there because a 5-byte string needs 6 bytes: the terminator is a byte too. The version that checks `src.len > dest.len` looks
right, compiles, passes a test with short strings, and writes exactly one byte
past the end of the buffer.

That single byte is the classic C buffer overflow. It needs no wild pointer
and no malicious input. It needs only an off-by-one in a bounds check that
somebody read twice and approved.

**Trimming returned a view.** `"  padded  "` became `"padded"` with nothing
copied and nothing allocated. The obvious implementation moves the bytes to
the front, and that work is wasted. The trimmed text is already in the input.
The function only has to return a slice that covers less of it.

## Check yourself

`strTrim` takes `[]const u8` and returns `[]const u8`. Could it take a
null-terminated C string and return one?

Not without copying the string or writing to it. Trimming the front is fine, since you
can just point further in. Trimming the back means the string has to end
earlier, and a C string ends where its zero is. So you would have to write a
zero over the first trailing space, modifying the caller's data. `strtok`
does exactly this, and that is why it is so unpleasant to use. A slice can
describe a shorter piece of the same bytes without touching them. Because of
this, a slice does not need a terminator.

## If you have written C

You have written all four of these, and probably more than once:

```c
size_t str_len(const char *s) { size_t i = 0; while (s[i]) i++; return i; }
int    str_eq(const char *a, const char *b) { return strcmp(a, b) == 0; }
void   str_copy(char *d, const char *s) { while ((*d++ = *s++)); }   /* no bounds at all */
```

The third one is `strcpy`, and it does not know how big the destination is.
The problem is in the signature, not the implementation: the function is never
given the size, so it cannot check it. `strncpy` was the fix, and it added its
own trap. It does not terminate the result when the source is too long. So the
safer replacement for `strncpy` is `strlcpy`, which is not in the C standard.

That is three attempts at one function. All three are awkward because a
`char *` is a pointer with no length. Everything above takes a slice, so the
length is not a separate argument anybody can pass wrongly.

Next: [tokenizing a command line](https://www.ziglang.in/learn/terminal/tokenize/), which is the
first thing a shell has to do.
