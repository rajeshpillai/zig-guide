# A Batch Job Runner

> Four workers, one batch, three kinds of shared state, and a measurement that says one thread did all of it.

Every other chapter here shows one primitive at a time.

This chapter is a whole program.

A batch of order records goes in, four workers process them, and a report comes out.

Three of the records are malformed, each in a different way, because a real batch runner cannot assume clean input.

```zig
const std = @import("std");

/// The batch. A `const` rather than stdin, so CI checks the same bytes the
/// chapter shows. Three records are malformed on purpose, each in a different
/// way, because a batch runner has to handle bad input.
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
/// which record it came from. The two fields have to agree with each other,
/// and a single atomic cannot keep two fields in agreement.
const Largest = struct {
    value: u64 = 0,
    index: usize = 0,
};

/// Turn one record into a `Result`. It uses no `Io`, allocator or shared
/// state, so it can be read and tested on its own.
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

        // The tie break on index is needed. Without it, two records of
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
    // completion order. The work runs concurrently, but the report is
    // printed in a fixed order.
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

*Built and run natively by CI. wasm32-wasi has a single thread, so every worker would run inline and the program would behave like a plain for loop. (`03-standard-library.batch-runner`)*

The program has three pieces of state that workers touch.

Each one is protected in a different way.

## Three kinds of state, three different answers

The results are one slot per record.

<SnippetSource name="03-standard-library.batch-runner" decl="Result" />

Each worker writes only the slot whose record it claimed, so two workers never touch the same bytes.

So the slots need no lock and no atomic.

This is the cheapest kind of sharing, and the first one to try.

The work index is a single number that every worker increments.

It is one machine word, changed by one operation, and it does not have to agree with any other value.

So an atomic is enough for it.

The largest order in the batch is the third kind.

<SnippetSource name="03-standard-library.batch-runner" decl="Largest" />

Two fields that have to agree with each other.

A value that belongs to an index, and an index that belongs to a value.

Atomic operations cannot keep that pair consistent, as [Atomics](https://www.ziglang.in/learn/concurrency/atomics/) explains at its end.

So the pair needs a mutex, and it is the only thing in the program that does.

## Claiming work with one atomic add

<SnippetSource name="03-standard-library.batch-runner" decl="worker" />

Every worker runs that same function and they compete for records.

`fetchAdd` returns the value from before the addition, so the index each worker gets is one nobody else can get.

That is how work gets handed out.

When the returned index is past the end, the worker returns and the batch is done.

Nothing counts or splits the batch up front, so no worker sits idle because its share happened to be the easy half.

## The parser knows nothing about any of this

<SnippetSource name="03-standard-library.batch-runner" decl="parseOrder" />

`parseOrder` takes no `Io` and no allocator, touches no shared state, and does not know that anything concurrent is happening.

You can read it and test it on its own.

A mistake in the concurrency cannot make the parsing wrong.

Keeping this part free of concurrency makes the whole program much easier to review.

The networking chapters keep protocol code away from sockets for the same reason.

## The tie break is not decoration

Look again at the comparison inside the lock.

A plain "greater than" would be enough to find the largest value.

It would not be enough to find it **the same way twice**.

Two records of equal value would leave whichever worker got there first in the answer, and that varies by machine, by run, and by how busy the box is.

The tie break on index gives the reduction a total order, so the result no longer depends on who arrived first.

Any reduction shared between workers needs this, whether it finds a maximum, a minimum, a first match or a best candidate.

If two inputs can tie, something other than arrival order has to decide between them.

## The run is concurrent, the report is not

Nothing prints until every worker has finished.

Then the report walks the results in record order, which is not the order they were produced in.

This is deliberate.

Every program on this site runs nightly, and its output is compared with a recorded file.

If the output depended on scheduling, nobody could check it.

The same rule applies outside this site.

If a concurrent program's result depends on the order its tasks happened to run, you cannot test it, and you will not notice when it starts giving wrong answers.

Make the result independent of scheduling, and you can change how the work runs later without changing the result.

## `group.async`, not `group.concurrent`

The workers start on a `Group`, and the spelling matters.

`group.async` is allowed to run a task inline when the pool is busy.

That is fine for these workers: each one finishes on its own, so running it on the calling thread still gets it done.

`group.concurrent` promises a separate unit of concurrency and returns an error when it cannot provide one.

Use `concurrent` when a task might not finish by itself, which in practice means anything you intend to cancel.

[Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) shows what goes wrong otherwise, including how it happened in this guide's own CI.

## What actually happened

I instrumented a copy of this program to record which thread claimed each record, and ran it on a twelve-core machine.

All twelve records went to one thread.

It happened on every run, whatever the per-record work was set to.

The first worker starts before the second one exists.

Twelve records is far too little work for the first worker to still be busy when the second one starts.

Raising the batch changes it.

At two hundred records the same binary gives a different answer run to run: one thread, then three, then two, on a quiet machine seconds apart.

At five thousand it is four every time.

So **the work index makes the batch safe to share, but it does not make it parallel**.

The safety comes from the structure, so it holds at any size.

Work runs in parallel only when there is enough of it that the first worker is still busy when the others start.

This is also why the report does not depend on scheduling.

The same program with the same input on the same machine split the work differently two seconds apart.

A report that mentioned threads would have been wrong by the time you read it.

## When this shape is the wrong one

A work index suits a fixed batch that is known up front.

Work that arrives while the program is running needs [`Io.Queue`](https://www.ziglang.in/learn/concurrency/queues/) instead.

There, producers and consumers run at the same time, and the queue's capacity limits how far producers can get ahead.

Work with a deadline needs [Select](https://www.ziglang.in/learn/concurrency/select/) around the group, and then cancellation for whatever has not finished.

Work where each job is a network round trip needs far more workers than cores, because the workers spend most of their time blocked, not computing.

Next: [Choosing an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) for the choice this program makes in one line, which the other chapters assume.
