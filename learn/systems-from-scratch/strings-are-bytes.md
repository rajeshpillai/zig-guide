# Strings Are Bytes

> Zig has no string type. A literal is bytes, with a zero at the end.

Chapter one said that everything is bytes. With text, that fact starts to have
a cost.

In the language that you know, a string is a thing. A string knows its length,
and you can compare two strings with `==`. When you ask for the length, you
get the number of letters that you count with your eyes. A different person
made all of that for you. In Zig, nobody made it.

Zig has only a sequence of bytes. Thus Zig has the same question that C had to
answer first. If you get the address of some text, **how do you know where the
text ends?**

C put a zero byte after the last character. This method costs little: one byte
for each string, and a pointer is all that you must pass. But to find the
length, the code must read all the text and look for the zero. If the zero is
not there, the read does not stop at the end of the text.

Zig keeps the zero for code that calls C, but Zig does not depend on it.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const greeting = "hello";

    // The type shows all that the memory stores: a pointer to five bytes, and
    // a zero after them. The length does not count the zero.
    try out.print("\"hello\" is a {s}\n", .{@typeName(@TypeOf(greeting))});
    try out.print("greeting.len       = {d}\n", .{greeting.len});
    try out.print("the array occupies = {d} bytes\n\n", .{@sizeOf(@TypeOf(greeting.*))});

    // An index gives a number, because the memory stores only a number.
    try out.print("greeting[0] = {d}, which prints as '{c}'\n\n", .{ greeting[0], greeting[0] });

    // Two separate literals with the same contents. Zig does not allow `==`
    // on slices. std.mem.eql compares the contents.
    const a: []const u8 = "cat";
    const b: []const u8 = "cat";
    try out.print("std.mem.eql(a, b) = {}\n\n", .{std.mem.eql(u8, a, b)});

    // A length in bytes is not a count of characters. On this string, you can
    // see the difference.
    const word = "héllo";
    try out.print("\"héllo\".len = {d} bytes\n", .{word.len});
    try out.print("codepoints  = {d}\n", .{try std.unicode.utf8CountCodepoints(word)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.strings-are-bytes`)*

## What just happened

**The type printed as `*const [5:0]u8`.** Read it as: a pointer to an array of
5 bytes, with a sentinel `0` after them. The type does not say "a string".
The type describes a specific number of specific bytes at a specific place.

**`.len` was 5, and the array was 6 bytes.** The terminator is really there,
and it uses memory, but the length does not count it, on purpose. Thus Zig
knows the length without a search. Zig can also give the pointer to a C
function that expects the zero. You get both answers to the question above,
and you do not have to select one.

**The index gave 104, not `'h'`.** The two are the same byte. The memory
stores `104`, and `'h'` is a way to print it. This fact is the point of
chapter one again, in a place where it is important.

**The comparison needed `std.mem.eql`.** Zig does not let you write `a == b`
on two slices. The compiler rejects it: `operator == not allowed for type
'[]const u8'`. You can compare two pointers with `==`, and the answer tells
you if they point at the same place. That question is valid, but it is not
the question that you wanted to ask. If you know a managed language, make
this a firm habit: **compare contents with `std.mem.eql`.**

**`"héllo".len` was 6 for five letters.** UTF-8 uses one byte for each ASCII
letter, and two to four bytes for each other character. Thus `é` uses two
bytes. A count of bytes and a count of characters are different questions,
with different answers. `.len` answers the question about bytes, because the
machine can answer that question without an inspection of the bytes.

## Check yourself

You have a `[]const u8`, and you want its third character. What is the problem
with `text[2]`?

If the text is ASCII, there is no problem. If the text can contain other
characters, `text[2]` is the third *byte*. That byte can be the middle of a
two-byte character, and then you get half of the character.

The correct method is to iterate over the codepoints with
`std.unicode.Utf8View`. [Unicode](https://www.ziglang.in/learn/standard-library/unicode/) tells
about this method. But usually, you do not want the character at an index. You
want to search, split or compare, and all of these operations work on bytes.

## If you know C

You already know the terminator and its cost:

```c
char *name = "hello";
strlen(name);            /* walks the string every time you ask */
if (name == "hello")     /* compares pointers, and compiles without complaint */
strcpy(dest, name);      /* writes until the zero, wherever that turns out to be */
```

The `strcpy` line caused real damage. `strcpy` trusts a terminator that it
cannot check. If the terminator is not there, `strcpy` continues to write.

A Zig slice holds the length next to the pointer. Thus functions do not have
to trust anything. `[:0]const u8` is the type for the case where a C function
also needs the zero. [Sentinel
Termination](https://www.ziglang.in/learn/language-basics/sentinel-termination/) gives the full set
of types, and how to get a C string back into Zig.

Next: [Structs Are Layout](https://www.ziglang.in/learn/systems-from-scratch/structs-are-layout/).
That chapter tells what occurs when you put several values together.
