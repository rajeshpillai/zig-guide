# sort

> Sorting lines is easy. Owning them is the part that costs you something.

The first three tools never held more than a bufferful. `sort` cannot: you
cannot know which line comes first until you have seen the last one. So this
is the chapter where the streaming loop breaks down and a question the earlier
tools never faced arrives.

**Where do the lines live?**

Reading them means holding all of them. Sorting them means moving them around.
And a moment after you have sorted, something has to still be pointing at the
right bytes. That is the ownership question from [Who Owns This
Memory](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/), turning up in the
first program where it is unavoidable.

There are two honest answers. Copy each line into memory you allocated, or
keep the whole input in one buffer and sort a list of *pointers into it*. The
second is what real `sort` does for anything that fits, because moving an
8-byte pointer is cheaper than moving a 200-byte line, and it costs nothing to
set up.

## The program

```zig
const std = @import("std");

/// Sort the lines of `text`, returning slices that point back into `text`.
/// Nothing is copied, so the result is only valid while `text` is, and the
/// caller frees exactly one thing: the list of pointers.
fn sortLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var reader: std.Io.Reader = .fixed(text);
    while (try reader.takeDelimiter('\n')) |line| {
        try lines.append(allocator, line);
    }

    const slice = try lines.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessThan);
    return slice;
}

/// Byte order, which is what `sort` does by default and why "Zebra" comes
/// before "apple": upper case is 65..90 and lower case is 97..122.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A fixed buffer, so this program never touches the heap. The arena the
    // C version carves by hand is this, with the bookkeeping already written.
    var storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);

    const text =
        \\banana
        \\Zebra
        \\apple
        \\cherry
        \\apple
        \\
    ;

    const sorted = try sortLines(fba.allocator(), text);
    defer fba.allocator().free(sorted);

    for (sorted) |line| try out.print("{s}\n", .{line});

    try out.print("\n{d} lines, {d} bytes of pointers, 0 bytes of copied text\n", .{
        sorted.len,
        sorted.len * @sizeOf([]const u8),
    });
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`16-unix-tools.sort`)*

## What just happened

**Nothing was copied.** The last line says so: 40 bytes of pointers and zero
bytes of copied text. Each entry in the sorted list is a slice pointing back
into the original input, so sorting five lines moved five pointers and left
the text exactly where it was.

The cost of that decision is written into the function's contract: the result
is only valid while the input buffer is. Return those slices from a function
that owned the buffer and you have the dangling pointer from [The
Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/), except now it is a whole array
of them.

**`Zebra` sorted before `apple`.** Not a bug: byte order. `Z` is 90 and `a` is
97, so every capital letter sorts before every lower-case one. This is what
`sort` does by default too, and it is why `LC_ALL=C sort` and `sort` can
disagree on the same file. Anything friendlier than byte order is a locale
question, not a sorting one.

**Both copies of `apple` survived.** Sorting does not deduplicate. `sort -u`
does, and it is a separate pass, because "are these adjacent lines equal" is
only cheap once they are sorted.

**The whole program touched no heap.** `FixedBufferAllocator` hands out chunks
of a 4 KB array on the stack. When it runs out it returns `error.OutOfMemory`
like any other allocator, which is the honest failure for a tool with a fixed
budget. The hand-carved arena in a C version of this is the same idea with the
bookkeeping written out by hand.

## Check yourself

The input has five lines and the program allocated one thing. What was it, and
what would have to change to sort a file too large to hold?

It allocated the *list of slices*, not the lines. To handle a file larger than
memory, you would sort what fits, write that run to a temporary file, and
repeat. Then merge the sorted runs, keeping one line from each in memory at a
time. That is an external merge sort. It is what the real `sort` switches to,
and the merge step is why `sort` has always been able to handle files bigger
than the machine it runs on.

## If you have written C

The pointer-table trick is the same, and in C you would build it by hand:

```c
char *lines[MAX_LINES];       /* pointers into one big buffer */
...
qsort(lines, n, sizeof(char *), cmp);
```

Two things Zig removes. `qsort`'s comparator receives `const void *` and
starts with a cast. That is where the classic bug lives. The argument is a
pointer to the array *element*, so for an array of `char *` it is a `char **`.
Get that one indirection wrong and it compiles cleanly and sorts garbage.
`std.mem.sort` is generic over the element type, so the comparator receives
the two elements themselves.

And `MAX_LINES` is a real limit that a C version has to pick in advance and
check on every append. `ArrayList` grows, and asks the allocator, and the
allocator is allowed to say no.

Next: [cut](https://www.ziglang.in/learn/unix-tools/cut/), which goes back to one line at a time.
