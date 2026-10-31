# Who Owns This Memory

> Memory that must stay valid after a call returns needs a request, and a person or a function must give it back.

A frame ends when the call returns. What do you do when the answer must stay
valid after the call that calculated it?

You ask for memory that does not belong to a frame. A second pool of memory
exists for this purpose. Its usual name is the **heap**, and its rules are
different:

- Frame memory costs nothing, is automatic, and has a short life.
- Heap memory needs a request. It stays valid until the program gives it
  back. If the program never gives it back, the program holds the memory
  until the program exits. The name for this problem is a **leak**.

Thus some part of the program must give the memory back. Memory management is
the answer to one question: **who owns this memory, and when does the owner
release it?** Each method that you know is an answer to this question:

- A garbage collector answers "nobody, the runtime decides later".
- Rust answers "the compiler tracks it".
- C answers "you do, and nothing helps you".
- Zig answers "you do, and the type signature shows it".

The last part makes Zig different. In Zig, **a function that allocates takes
an allocator as an argument**. Zig has no global `malloc` that a function can
use. Thus a function that needs memory cannot hide the request. The allocator
is in the signature, and you can see it at each call site. A function without
that parameter cannot allocate without your knowledge.

## The program

```zig
const std = @import("std");

/// Fills a buffer from the caller. This function allocates nothing. Thus the
/// function owns nothing, and the caller has nothing to release.
fn writeGreeting(into: []u8, name: []const u8) []u8 {
    return std.mem.print(into, "hello, {s}", .{name}) catch into[0..0];
}

/// Returns memory of its own. The doc comment holds the rule: the caller owns
/// the result, and must free it with the same allocator.
fn makeGreeting(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.print("hello, {s}", .{name});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // This memory is in the frame of this call, and it ends when main
    // returns. For the same reason, the function above cannot return memory
    // from its own frame.
    var scratch: [64]u8 = undefined;
    try out.print("{s}\n", .{writeGreeting(&scratch, "stack")});

    // This memory needs a request. Nothing in Zig allocates without an
    // allocator argument. Thus each place that can allocate says so.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = safe.allocator();

    {
        const greeting = try makeGreeting(allocator, "heap");
        defer allocator.free(greeting); // runs at the end of this block
        try out.print("{s}\n", .{greeting});
    }

    // deinit answers one question: how many allocations did the program not free?
    try out.print("allocations never freed: {d}\n\n", .{safe.deinit()});

    // The same program without the `defer`. At the end, the program asks the
    // allocator if the program freed all its memory, and the allocator answers.
    var leaky: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    {
        const greeting = try makeGreeting(leaky.allocator(), "forgotten");
        try out.print("{s}\n", .{greeting});
    }
    try out.print("allocations never freed: {d}\n", .{leaky.deinit()});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.who-owns-this-memory`)*

## What just happened

**The first function allocated nothing.** `writeGreeting` takes a buffer from
the caller and writes into the buffer. The function owns nothing. Thus it has
nothing to release, and it cannot leak. Use this method more frequently than
a beginner in systems programming expects. Many jobs look as if they need the
heap, but they only need the caller to supply the space.

**The second function returns memory that it asked for.** `makeGreeting`
takes an `std.mem.Allocator` and returns a slice from that allocator. The
caller now owns the slice. The type system does not make this rule true. Thus
the rule is in the place where the reader looks: the doc comment on the
function.

**`defer` gives the memory back.** Put `defer allocator.free(greeting);` on
the line after the allocation. Then the release occurs when the block ends,
in all the ways that the block can end. The two lines are next to each other,
thus you can see the pair at one time. The other method is a cleanup section
at the bottom of the function, and a hope that each path gets to it.

**The allocator answered the question at the end.** `SafeAllocator` records
the memory that it gave out. A call to `deinit` reports how many allocations
the program did not free. The count is 0 the first time. The count is 1 in the
block that has no `defer`.

`deinit` also writes a description of the leaked block to standard error. For
this reason, use this allocator during development.

This report is the reason to learn ownership in Zig and not in C. You do not
find a leak in production three months later, when a server fails. The leak is
a number that the program prints before it exits. In tests, a leak makes the
build fail: `std.testing.allocator` fails each test that leaks.

## Check yourself

In the block that leaks, why does an earlier call to `deinit` not help?

`deinit` does not free the allocation. `deinit` is the audit. The function
that frees memory is `allocator.free`, and the block never calls it. An
earlier call to `deinit` would ask the question earlier and get the same
answer. The allocator would also be unusable for the code after the call.

The correct repair is to add the `defer`. The report tells you that the code
broke a rule. The report does not tell you the correct repair.

## If you know C

The two languages are almost the same here, but they are different in one
place:

```c
char *greeting = malloc(32);   /* where did this memory come from? */
if (!greeting) return NULL;    /* and who checks? */
/* ... */
free(greeting);                /* and who remembers, on every path out? */
```

The Zig `allocator.alloc` is `malloc`, but the call site names the source of
the memory. The failure is in the return type. Thus `try` handles the failure,
and you cannot forget the null check, because no null exists. Also, `defer`
puts the `free` next to the `alloc`, not at each exit from the function. Thus
the usual C ladder of `goto cleanup` labels is not necessary.

[Allocators](https://www.ziglang.in/learn/standard-library/allocators/) tells about the other
allocators in Zig:

- arenas that free all their memory at one time
- fixed buffers that never use the heap
- the allocator above, which finds leaks

Next: [Off the End](https://www.ziglang.in/learn/systems-from-scratch/off-the-end/). That chapter
tells what occurs when you read memory that you own, but not the part that you
wanted.
