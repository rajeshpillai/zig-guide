# Who Owns This Memory

> Memory that outlives a call has to be asked for, and somebody has to give it back.

A frame goes away when the call returns. So what do you do when the answer has
to outlive the call that computed it?

You ask for memory that is not tied to a frame. There is a second pool for
exactly this, usually called the **heap**, and the deal is different. Frame
memory is free and automatic and short-lived. Heap memory has to be requested,
lasts until it is handed back, and if it is never handed back, the program
holds it until it exits. That is a **leak**.

So somebody has to be responsible for handing it back. The whole of memory
management is that one question: **who owns this, and when do they give it
up?** Every scheme you have heard of is an answer to it. A garbage collector
answers "nobody, the runtime works it out later". Rust answers "the compiler
tracks it". C answers "you do, good luck". Zig answers "you do, and the type
signature will say so".

That last part is the difference that matters. In Zig, **a function that
allocates takes an allocator as an argument**. There is no global `malloc` to
reach for. So a function that needs memory cannot hide it. The allocator is in
the signature, visible at every call site. A function without that parameter
cannot be allocating without your knowledge.

## The program

```zig
const std = @import("std");

/// Fills a caller-supplied buffer. This function allocates nothing, so there
/// is nothing for it to own and nothing for the caller to release.
fn writeGreeting(into: []u8, name: []const u8) []u8 {
    return std.mem.print(into, "hello, {s}", .{name}) catch into[0..0];
}

/// Returns memory of its own. The doc comment is where the rule lives: the
/// caller owns the result and has to free it with the same allocator.
fn makeGreeting(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.print("hello, {s}", .{name});
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Memory you can point at. It lives in this call's frame and is gone when
    // main returns, which is exactly why the function above cannot return it.
    var scratch: [64]u8 = undefined;
    try out.print("{s}\n", .{writeGreeting(&scratch, "stack")});

    // Memory that has to be asked for. Nothing in Zig allocates without an
    // allocator argument, so the places that can are the places that say so.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = safe.allocator();

    {
        const greeting = try makeGreeting(allocator, "heap");
        defer allocator.free(greeting); // runs when this block ends
        try out.print("{s}\n", .{greeting});
    }

    // deinit answers one question: how many allocations were never returned.
    try out.print("allocations never freed: {d}\n\n", .{safe.deinit()});

    // The same program with the `defer` removed. The allocator is asked at the
    // end whether everything it handed out came back, and it says so.
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

**The first function allocated nothing.** `writeGreeting` takes a buffer the
caller already has and writes into it. It owns nothing, so there is nothing to
release, and it cannot leak. Reach for this more often than people new to
systems programming expect. Plenty of jobs that look like they need the heap
just need the caller to supply the space.

**The second one returns memory it asked for.** `makeGreeting` takes an
`std.mem.Allocator` and returns a slice that came from it. The caller now owns
that slice. Nothing in the type system enforces this, so the convention is
written where the reader will look: in the doc comment on the function.

**`defer` is how the giving-back gets done.** Writing
`defer allocator.free(greeting);` on the line after the allocation schedules
the release for when the block ends, however it ends. The two lines sit next
to each other, so you can see the pair in one look. The alternative is
scrolling to a cleanup section at the bottom and hoping every path reaches it.

**The allocator answered the question at the end.** `SafeAllocator` remembers
what it handed out. Calling `deinit` reports how many allocations never came
back: 0 the first time, and 1 in the block where the `defer` was left out. It
also writes a description of the leaked block to standard error, which is why
this is the allocator to use while developing.

That last part is the reason to learn ownership in Zig rather than in C. A
leak is not something you discover in production three months later when a
server falls over. It is a number the program prints before it exits, and in
tests it is a red build: `std.testing.allocator` fails any test that leaks.

## Check yourself

In the leaking block, why does moving the `deinit` call earlier not help?

Because `deinit` is not what frees the allocation. It is the audit. Freeing is
`allocator.free`, and the block never calls it. Calling `deinit` sooner would
just ask the question sooner and get the same answer, and it would also make
the allocator unusable for the code after it. The fix is the missing `defer`,
which is the point: the report tells you a rule was broken, not what the rule
should have been.

## If you have written C

The shapes line up almost exactly, and then diverge in one place:

```c
char *greeting = malloc(32);   /* where did this memory come from? */
if (!greeting) return NULL;    /* and who checks? */
/* ... */
free(greeting);                /* and who remembers, on every path out? */
```

Zig's `allocator.alloc` is `malloc` with the source named at the call site
instead of assumed. Its failure is in the return type, so `try` handles it and
you cannot forget the null check, because there is no null to check. And
`defer` puts the `free` next to the `alloc` rather than at every exit from the
function, which is the shape that makes the classic `goto cleanup` ladder
unnecessary.

The rest of what Zig ships, arenas that free everything at once, fixed buffers
that never touch the heap, and the leak-checking allocator used above, is in
[Allocators](https://www.ziglang.in/learn/standard-library/allocators/).

Next: [Off the End](https://www.ziglang.in/learn/systems-from-scratch/off-the-end/), which is what
happens when you read memory you do own, just not the part you meant.
