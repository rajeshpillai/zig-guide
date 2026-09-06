# Off the End

> A length is a value, and the difference between languages is who is made to check it.

An array of four numbers occupies a stretch of memory, and the stretch ends.
What is at the address just past it? Something. Another variable, part of a
frame, the machinery of the program itself. Memory does not run out at the end
of your array; your claim on it does.

So what should `row[4]` do?

There are only three possible answers and every language picks one. Read
whatever happens to be there and carry on. Stop the program. Or refuse to be
asked, by making the caller check first. The third is the only one that is
free, so that is where to start.

## The program

```zig
const std = @import("std");
const builtin = @import("builtin");

/// Reading an element without assuming the caller checked first.
fn at(numbers: []const u32, index: usize) !u32 {
    if (index >= numbers.len) return error.OutOfBounds;
    return numbers[index];
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const row = [_]u32{ 10, 20, 30, 40 };

    // A slice is a pointer and a length travelling together, so a function
    // that receives one cannot be ignorant of where the data stops.
    const slice: []const u32 = &row;
    try out.print("the slice has {d} elements\n", .{slice.len});
    try out.print("a slice is {d} bytes: a pointer and a length\n\n", .{@sizeOf([]const u32)});

    // Valid index.
    if (at(slice, 2)) |value| {
        try out.print("element 2 is {d}\n", .{value});
    } else |err| {
        try out.print("element 2: {t}\n", .{err});
    }

    // One past the end. Nothing is read; the caller is told.
    if (at(slice, 4)) |value| {
        try out.print("element 4 is {d}\n", .{value});
    } else |err| {
        try out.print("element 4: {t}\n", .{err});
    }

    // The check the language inserts for `slice[i]` is this comparison, and
    // whether it is present depends on the build.
    try out.print("\nsafety checks in this build: {}\n", .{builtin.mode.runtimeSafety()});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.off-the-end`)*

## What just happened

**The slice knew where it ended.** A slice is a pointer and a length travelling
together as one value, so a function receiving one cannot be ignorant of the
size. This is the single most useful thing Zig does with memory, and it is why
`[]const u32` rather than a bare pointer is the normal way to pass a sequence
around. The pointer alone would have told the function where the data starts
and nothing about where to stop.

**The slice printed as 8 bytes.** Four for the pointer and four for the length,
on this 32-bit WebAssembly build. Compile it for your own machine and it
prints 16, for the same reason a pointer there is 8 bytes rather than 4.

**The checked read returned an error instead of a number.** `at` compares the
index against `.len` and returns `error.OutOfBounds` when it does not fit.
Nothing was read. The caller was told, in the return type, that the answer
might not exist, and had to deal with both cases before it could use the
result. One comparison bought that.

**And then the last line said `safety checks in this build: false`.**

## About that last line

This is the honest part, and it is worth more to you than a tidier page would
be.

When you write `slice[i]` directly, Zig inserts that same comparison for you,
and on failure the program stops with a message naming the index and the
length. That check exists in Debug and ReleaseSafe builds. It does not exist
in ReleaseFast or ReleaseSmall, where it is compiled out for speed and size.

The wasm you just ran is a ReleaseSmall build, because that is what gets
shipped to a reader's browser. So on this page, `slice[4]` would not stop the
program. It would read four bytes that are not yours and hand them over as a
number.

Here is the program that does it. This one is the exception on this site: it
is built ReleaseSafe rather than ReleaseSmall, so the check is present, and it
is here to stop. Press **Run**.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const row = [_]u32{ 10, 20, 30, 40 };
    const slice: []const u32 = &row;

    // `index` is a `var` whose value the compiler cannot fold, so this is not
    // rejected at compile time. The check that stops it runs while the program
    // is running, which is the whole point: the compiler cannot know.
    var index: usize = 4;
    _ = &index;

    std.debug.print("value: {d}\n", .{slice[index]});
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.past-the-end`)*

```
panic: index out of bounds: index 4, len 4
```

Nothing was read. The program named the index it was given and the length it
was allowed, and stopped on the line that asked. Compare that with the silent
wrong answer at the top of this page: the mistake is the same, and the
difference is entirely in whether the check was compiled in.

The run also says it cannot print a stack trace. That is WebAssembly, not Zig:
there is no call stack here to walk. On your own machine the same panic comes
with the chain of calls that led to it, file and line for each.

That message is not quoted from memory. Our build runs this program on every
change and requires it to stop with exactly that text. If a future Zig worded
the panic differently, this page would fail to publish. It cannot quietly
teach you a message you would never see.

This snippet is about 1.1 MB, against 46 KB for the program at the top of this
page. That gap is what the safety checks and the machinery to describe them
cost, and it is the honest reason the rest of the site does not carry them. It
downloads only when you press Run.

The general rule behind this, what each build mode turns off and what you are
promising when you choose one, is [When the Checks Are
Off](https://www.ziglang.in/learn/systems-from-scratch/when-checks-are-off/).

## Check yourself

The program checks `index >= numbers.len`. Why not `index > numbers.len`?

Because the indexes of four elements are 0, 1, 2 and 3. Index 4 is the first
one past the end, so it has to be rejected. Being off by one at exactly this
boundary is common enough to have a name: the fencepost error. It is the
reason to prefer `for (slice) |item|` over an index and a counter whenever you
do not actually need the number.

## If you have written C

This is the difference that shows up first and matters most.

```c
int row[4] = {10, 20, 30, 40};
int x = row[4];        /* reads something. no error, no warning, no crash */
```

C's array does not carry a length, so a function receiving `int *row` cannot
check anything; the length has to be passed alongside and kept correct by
hand. Reading past the end is undefined behaviour, which in practice means it
usually works, sometimes returns nonsense, and occasionally corrupts something
that fails much later somewhere unrelated.

Zig has two answers to it. The slice carries the length, so the length cannot
get out of step with the data. The safety check turns "usually works" into a
message with a line number. Both are what make this material learnable: you
find out at the moment you make the mistake rather than an hour later.

The C-shaped pointer, the one without a length, still exists in Zig for
talking to C, and it is spelled differently on purpose: [many-item
pointers](https://www.ziglang.in/learn/language-basics/many-item-pointers/).

Next: [When the Checks Are
Off](https://www.ziglang.in/learn/systems-from-scratch/when-checks-are-off/), which is the promise
you make when you turn a check off.
