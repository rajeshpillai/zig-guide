# A Batch Job Runner

> Four workers, one batch, three kinds of shared state, and a measurement that says one thread did all of it.

Every other chapter here shows one primitive at a time.

This is a whole program.

A batch of order records goes in, four workers process them, and a report comes out.

Three of the records are malformed, each in a different way, because a batch runner that assumes clean input is not one.

```zig
const std = @import("std");

/// The batch. A `const` rather than stdin, so CI checks the same bytes the
/// chapter shows. Three records are malformed on purpose, each in a different
/// way, because a batch runner that assumes clean input is not one.
const input =
    \\1001,3,450
    \\1002,1,300
    \\1003,0,995
    \\1004,2,1250
    \\1005,x,100
    \\1006,4,275
    \\1007,7,880
    \\1008,2
    \\1009,1,1600
    \\1010,5,120
    \\1011,3,640
    \\1012,2,410
;

const worker_count = 4;
const capacity = 32;

/// One record's outcome. Each worker writes only the slot it claimed, so this
/// needs no lock at all.
const Result = struct {
    id: u32 = 0,
    total: u64 = 0,
    failure: ?[]const u8 = null,
};

/// The only state the workers really share: the biggest order in the batch and
/// which record it came from. Two fields that have to agree with each other,
/// which is exactly what an atomic cannot give you.
const Largest = struct {
    value: u64 = 0,
    index: usize = 0,
};

/// Turn one record into a `Result`. No `Io`, no allocator, no shared state, so
/// it can be read and tested on its own.
fn parseOrder(line: []const u8) Result {
    var fields = std.mem.splitScalar(u8, line, ',');
    const id_text = fields.next() orelse return .{ .failure = "no id" };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return .{ .failure = "bad id" };

    // The id is read before anything else can fail, so every line of the
    // report names the record it is about.
    const quantity_text = fields.next() orelse return .{ .id = id, .failure = "missing quantity" };
    const price_text = fields.next() orelse return .{ .id = id, .failure = "missing price" };
    if (fields.next() != null) return .{ .id = id, .failure = "extra field" };

    const quantity = std.fmt.parseInt(u32, quantity_text, 10) catch
        return .{ .id = id, .failure = "bad quantity" };
    const price = std.fmt.parseInt(u64, price_text, 10) catch
        return .{ .id = id, .failure = "bad price" };
    if (quantity == 0) return .{ .id = id, .failure = "zero quantity" };

    return .{ .id = id, .total = @as(u64, quantity) * price };
}

/// Claim records until there are none left. Every worker runs this same
/// function, and which records each one gets is up to the scheduler.
fn worker(
    io: std.Io,
    records: []const []const u8,
    results: []Result,
    next: *std.atomic.Value(usize),
    largest: *Largest,
    mutex: *std.Io.Mutex,
) void {
    while (true) {
        // One atomic add hands out one record. `fetchAdd` returns the value
        // from before the add, so no two workers can claim the same index.
        const index = next.fetchAdd(1, .monotonic);
        if (index >= records.len) return;

        const result = parseOrder(records[index]);
        results[index] = result;
        if (result.failure != null) continue;

        mutex.lock(io) catch return;
        defer mutex.unlock(io);

        // The tie break on index is not decoration. Without it, two records of
        // equal value would leave whichever worker got there first in the
        // answer, and the program would print a different line on a different
        // machine.
        if (result.total > largest.value or
            (result.total == largest.value and index < largest.index))
        {
            largest.* = .{ .value = result.total, .index = index };
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // Cutting the batch into records is sequential work, done once, before any
    // worker starts. Handing out slices is what makes the rest parallel.
    var reader: std.Io.Reader = .fixed(input);
    var lines: [capacity][]const u8 = undefined;
    var count: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        lines[count] = line;
        count += 1;
    }
    const records = lines[0..count];

    var results: [capacity]Result = @splat(.{});
    var next: std.atomic.Value(usize) = .init(0);
    var largest: Largest = .{};
    var mutex: std.Io.Mutex = .init;

    // `group.async` rather than `group.concurrent`: these tasks all finish on
    // their own, so an `Io` that runs one inline because its pool is busy is
    // still correct. Anything you intend to cancel needs `concurrent`.
    var group: std.Io.Group = .init;
    for (0..worker_count) |_| {
        group.async(io, worker, .{ io, records, results[0..count], &next, &largest, &mutex });
    }
    try group.await(io);

    // Printing happens after every worker is done, in record order rather than
    // completion order. The run is concurrent; the report is not.
    var ok: usize = 0;
    var value: u64 = 0;
    try out.print("  id     total  status\n", .{});
    for (results[0..count]) |result| {
        if (result.failure) |why| {
            try out.print("{d: >6} {s: >9}  {s}\n", .{ result.id, "-", why });
        } else {
            ok += 1;
            value += result.total;
            try out.print("{d: >6} {d: >9}  ok\n", .{ result.id, result.total });
        }
    }

    try out.print("\n{d} records, {d} ok, {d} failed\n", .{ count, ok, count - ok });
    try out.print("total value: {d}\n", .{value});
    try out.print("largest: record {d} (id {d}) at {d}\n", .{
        largest.index,
        results[largest.index].id,
        largest.value,
    });

    try out.flush();
}
```

*Built and run natively by CI. wasm32-wasi has a single thread, so every worker would run inline and this would be a for loop wearing a costume. (`03-standard-library.batch-runner`)*

The interesting part is not the parsing.

It is that the program has three pieces of state that workers touch, and each one gets a different answer.

## Three kinds of state, three different answers

The results are one slot per record.

<SnippetSource name="03-standard-library.batch-runner" decl="Result" />

Each worker writes only the slot whose record it claimed, so two workers never touch the same bytes.

No lock, no atomic, nothing.

This is the cheapest kind of sharing there is, and the first thing to reach for.

The work index is a single number that every worker increments.

One machine word, one operation, no invariant spanning anything else.

That is an atomic.

The largest order in the batch is the third kind.

<SnippetSource name="03-standard-library.batch-runner" decl="Largest" />

Two fields that have to agree with each other.

A value that belongs to an index, and an index that belongs to a value.

No arrangement of atomic operations protects that pair, which is the rule [Atomics](https://www.ziglang.in/learn/concurrency/atomics/) ends on.

So it takes a mutex, and it is the only thing in the program that does.

## Claiming work with one atomic add

<SnippetSource name="03-standard-library.batch-runner" decl="worker" />

Every worker runs that same function and they compete for records.

`fetchAdd` returns the value from before the addition, so the index each worker gets is one nobody else can get.

That property is the whole handout mechanism.

When the returned index is past the end, the worker returns and the batch is done.

There is no counting, no partitioning up front, and no worker sitting idle because its share happened to be the easy half.

## The parser knows nothing about any of this

<SnippetSource name="03-standard-library.batch-runner" decl="parseOrder" />

No `Io`. No allocator. No shared state. No awareness that anything concurrent is happening.

You can read it on its own, test it on its own, and be wrong about the concurrency without being wrong about the parsing.

Keeping the pure part pure is most of what makes concurrent code reviewable, and it is the same discipline the networking chapters use to keep protocol code away from sockets.

## The tie break is not decoration

Look again at the comparison inside the lock.

A plain "greater than" would be enough to find the largest value.

It would not be enough to find it **the same way twice**.

Two records of equal value would leave whichever worker got there first in the answer, and that varies by machine, by run, and by how busy the box is.

The tie break on index gives the reduction a total order, so the result stops depending on who arrived first.

Any reduction shared between workers needs this.

Maximum, minimum, first match, best candidate: if two inputs can tie, something other than arrival has to break it.

## The run is concurrent, the report is not

Nothing prints until every worker has finished.

Then the report walks the results in record order, which is not the order they were produced in.

That is deliberate and it is the constraint this whole site is built on.

Every program here is run nightly and its output diffed against a recorded file, so a program whose output depends on scheduling is one nobody can check.

The rule generalises past this site.

A concurrent program whose result depends on the order its tasks happened to run is a program you cannot test, and you will not find the day it starts being wrong.

Design the result to be scheduling-independent, and the concurrency becomes something you can change your mind about later.

## `group.async`, not `group.concurrent`

The workers start on a `Group`, and the spelling matters.

`group.async` is allowed to run a task inline when the pool is busy, which for these workers is fine: each one finishes on its own, so running it on the calling thread still gets it done.

`group.concurrent` promises a separate unit of concurrency and fails loudly when it cannot deliver one.

Reach for `concurrent` the moment a task might not finish by itself, which in practice means anything you intend to cancel.

A task that only ends when cancelled, running inline on the thread that was about to cancel it, is a deadlock that appears on a small machine and never on yours.

[Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) has the full version of that trap, including the shape it took in this guide's own CI.

## What actually happened

Here is the part that no concurrency tutorial prints.

I instrumented a copy of this program to record which thread claimed each record, and ran it on a twelve-core machine.

All twelve records went to one thread.

Not most of them. All of them, on every run, whatever the per-record work was set to.

The first worker starts before the second one exists, and twelve records is nowhere near enough work to still be busy when the second arrives.

Raising the batch changes it.

At two hundred records the same binary gives a different answer run to run: one thread, then three, then two, on a quiet machine seconds apart.

At five thousand it is four every time.

So the number to carry away is not four, and it is not one.

It is that **the work index makes the batch safe to share, not parallel**.

Safety is structural and holds at any size.

Parallelism only turns up when there is enough work that the first worker is still going when the others arrive.

It is also the sharpest argument for the previous section.

The same program, the same input, the same machine, two seconds apart, and a different distribution of work.

Any report that mentioned threads would have been wrong by the time you read it.

## When this shape is the wrong one

A fixed batch known up front is what a work index suits.

Work that arrives while the program is running wants [`Io.Queue`](https://www.ziglang.in/learn/concurrency/queues/) instead, where producers and consumers run at the same time and the queue's capacity is the back pressure between them.

Work with a deadline wants [Select](https://www.ziglang.in/learn/concurrency/select/) around the group, and then cancellation for whatever has not finished.

Work where each job is a network round trip wants far more workers than cores, because they will spend their lives blocked rather than computing.

Next: [Choosing an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) for the decision this program makes in one line and every other chapter takes as given.
