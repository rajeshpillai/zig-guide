# sort

> To sort lines is easy. To own the lines is the part that has a cost.

The first three tools never held more than one full buffer. `sort` cannot do
that. You cannot know which line comes first until you see the last line.
Thus in this chapter, the streaming loop stops. The chapter has a question
that the earlier tools did not have.

**Where are the lines in memory?**

To read the lines, the program must hold all of them. To sort the lines, the
program must move them. After the sort, something must still point at the
correct bytes. This is the ownership question from [Who Owns This
Memory](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/). `sort` is the first
program where you cannot avoid the question.

There are two answers that work:

- Copy each line into memory that you allocated.
- Keep the full input in one buffer, and sort a list of *pointers into the
  buffer*.

For all input that fits, the real `sort` uses the second answer. To move an
8-byte pointer costs less than to move a 200-byte line, and the preparation
costs nothing.

## The program

```zig
const std = @import("std");

/// Sort the lines of `text`, and return slices that point back into `text`.
/// The function copies nothing. Thus the result is valid only while `text` is
/// valid. The caller frees exactly one thing: the list of pointers.
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

/// Byte order, as in `LC_ALL=C sort`. Thus "Zebra" comes before "apple":
/// upper case is 65..90, and lower case is 97..122.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A fixed buffer, so this program never uses the heap. The C version builds
    // this arena by hand. Here, the bookkeeping is already written.
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

**The program copied nothing.** The last line shows this: 40 bytes of pointers
and zero bytes of copied text. Each entry in the sorted list is a slice that
points back into the original input. Thus the sort of five lines moved five
pointers, and the text stayed exactly where it was.

The contract of the function states the cost of that decision: the result is
valid only while the input buffer is valid. Assume that a function owns the
buffer and returns those slices. Then you have the dangling pointer from [The
Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/), but now you have a full array
of dangling pointers.

**`Zebra` sorted before `apple`.** This is not a bug. It is byte order. `Z` is
90 and `a` is 97, so each capital letter sorts before each lower-case letter.
`LC_ALL=C sort` does the same.

Plain `sort` uses the collation of the locale, and the collation puts `apple`
first. For this reason, the two commands give different results on the same
file. An order that is easier for people than byte order is a question about
the locale, not about the sort.

**Both copies of `apple` stayed.** A sort does not remove duplicates. `sort -u`
removes them, in a separate pass. The question "are these adjacent lines
equal?" is cheap only after the sort.

**The full program used no heap.** `FixedBufferAllocator` gives out parts of a
4 KB array on the stack. When the array is full, the allocator returns
`error.OutOfMemory`, as all other allocators do. That is the correct failure
for a tool with a fixed memory budget. A C version uses an arena for the same
job, and the programmer writes the bookkeeping by hand.

## Check yourself

The input has five lines, and the program allocated one thing. What was it?
What must change to sort a file that is too large for memory?

The program allocated the *list of slices*, not the lines. For a file that is
larger than memory, do these steps:

1. Sort the part that fits.
2. Write that sorted run to a temporary file.
3. Do steps 1 and 2 again until no input remains.
4. Merge the sorted runs. Keep only one line from each run in memory at a
   time.

That is an external merge sort. The real `sort` changes to this method for
large files. Because of the merge step, `sort` always could handle files that
are larger than the computer that it runs on.

## If you know C

The table of pointers is the same, and in C you build it by hand:

```c
char *lines[MAX_LINES];       /* pointers into one big buffer */
...
qsort(lines, n, sizeof(char *), cmp);
```

Zig removes two problems. The first problem: the comparator of `qsort` gets
`const void *` and starts with a cast. The classic bug is in that cast.

The argument is a pointer to the array *element*. Thus for an array of
`char *`, the argument is a `char **`. If you get that one indirection wrong,
the code compiles without a warning and sorts garbage. `std.mem.sort` is
generic over the element type, so the comparator gets the two elements
themselves.

The second problem: `MAX_LINES` is a real limit. A C version must select the
limit in advance and check it on each append. `ArrayList` grows and asks the
allocator for memory, and the allocator can refuse.

Next: [cut](https://www.ziglang.in/learn/unix-tools/cut/), which returns to one line at a time.
