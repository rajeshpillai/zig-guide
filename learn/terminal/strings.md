# String Primitives

> strlen, compare, copy and trim, written out. The off-by-one error occurs in these functions.

The other chapters in this track need four operations on text: measure, compare,
copy and trim. Write these four functions one time. You learn more from that
than from a description, because three of the four functions have a well-known
mistake.

## The program

```zig
const std = @import("std");

/// Walk the string until the zero byte. C calls this function `strlen`. Its
/// cost is the reason that a slice holds its length. Each call is O(n). A call
/// inside a loop changes an O(n) job into O(n^2) work.
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

/// Copy `src` into `dest` and terminate the copy. If `src` is too large for
/// `dest`, return null. Do not write a part of `src`.
///
/// The `+ 1` is for the terminator. A 5-byte string needs 6 bytes of space.
/// A version that checks `src.len > dest.len` compiles and passes a simple
/// test. But that version writes one byte past the end of the buffer.
fn strCopy(dest: []u8, src: []const u8) ?[:0]u8 {
    if (src.len + 1 > dest.len) return null;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return dest[0..src.len :0];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Trim both ends, and do not move a byte. A trim does not need a copy. The
/// result is a slice of the bytes that you already have.
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

    // Six bytes of space for five bytes of text.
    var room: [6]u8 = undefined;
    if (strCopy(&room, "hello")) |copied| {
        try out.print("copied \"{s}\" into 6 bytes, terminator at index {d}\n", .{ copied, copied.len });
    }
    var tight: [5]u8 = undefined;
    try out.print("copying \"hello\" into 5 bytes -> {s}\n\n", .{
        if (strCopy(&tight, "hello") == null) "refused" else "wrote",
    });

    // This buffer is separate from `buf`. An earlier version gave `buf` here.
    // Then `buf` held the data of the writer and the data of `escape`, and
    // this garbled the first line of output. Both slices hold a length. Thus the
    // mistake garbled the output, and did not write past the end of a buffer.
    var scratch: [64]u8 = undefined;
    for ([_][]const u8{ "  padded  ", "\tboth\n", "none", "   ", "" }) |sample| {
        try out.print("trim(\"{s}\") -> \"{s}\"\n", .{ escape(sample, &scratch), strTrim(sample) });
    }

    try out.flush();
}

/// Show whitespace as visible text, so that you can check the trim by eye.
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

**`strLen` walks the string, and `.len` does not.** Both printed 5. `strLen`
counted bytes until it found a zero. `.len` read a number that the slice
already holds.

For a five-byte greeting, the difference is almost zero. In a loop, the
difference can be large:

```c
for (int i = 0; i < strlen(s); i++)   /* walks the string on every iteration */
```

The loop does an O(n) job with O(n²) work. This is a common performance bug in
C. You cannot write this bug with a slice, because no call exists that you can
repeat by accident.

**`strEq` compares the lengths first.** When the lengths are different, a
comparison of the contents is unnecessary work. More important, a loop without
the length check reads past the end of the shorter string. `"cat"` against
`"cats"` is false after one comparison.

**The copy refused the text and did not truncate it.** A buffer of six bytes
accepted `"hello"`, and a buffer of five bytes did not. The check is
`src.len + 1 > dest.len`. The `+ 1` is necessary because a 5-byte string needs
6 bytes: the terminator is also a byte.

Another version of the check is `src.len > dest.len`. That version looks
correct and compiles. It also passes a test with short strings. But it writes
exactly one byte past the end of the buffer.

That one byte is the classic C buffer overflow. It does not need a bad pointer
or malicious input. It needs only an off-by-one error in a bounds check, after
a reviewer read the check two times and approved it.

**The trim returned a view.** `"  padded  "` became `"padded"`, and the
function copied nothing and allocated nothing. The obvious implementation moves
the bytes to the front, and that work is unnecessary. The trimmed text is
already in the input. The function only returns a slice that covers a smaller
part of the input.

## Check yourself

`strTrim` takes `[]const u8` and returns `[]const u8`. Can it take a
null-terminated C string and return a null-terminated C string?

Not without a copy of the string or a write to the string. To trim the front is
easy, because the function can point further into the string. To trim the back,
the string must end earlier, and a C string ends at its zero byte.

Thus the function must write a zero over the first trailing space, and that
write changes the data of the caller. `strtok` does exactly this, and this
behavior makes `strtok` difficult to use. A slice can describe a shorter part
of the same bytes and not change them. For this reason, a slice does not need
a terminator.

## If you know C

You wrote these four functions before, possibly more than one time:

```c
size_t str_len(const char *s) { size_t i = 0; while (s[i]) i++; return i; }
int    str_eq(const char *a, const char *b) { return strcmp(a, b) == 0; }
void   str_copy(char *d, const char *s) { while ((*d++ = *s++)); }   /* no bounds at all */
```

The third function is `strcpy`, and it does not know the size of the
destination. The problem is in the signature, not in the implementation. The
caller never gives the size to the function, so the function cannot check the
size.

`strncpy` was the fix, and it added a new problem. It does not terminate the
result when the source is too long. Thus the safer replacement for `strncpy` is
`strlcpy`, and `strlcpy` is not in the C standard.

That is three attempts at one function. All three are difficult to use because
a `char *` is a pointer with no length. Each function above takes a slice. Thus
the length is not a separate argument that a caller can give incorrectly.

Next: [tokenize a command line](https://www.ziglang.in/learn/terminal/tokenize/). A shell does this
step first.
