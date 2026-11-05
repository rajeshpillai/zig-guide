# A Batch Job Runner

> Four workers, one batch, three kinds of shared state, and a measurement that says one thread did all of the work.

Each other chapter here shows one primitive at a time. This chapter is a full program.

A batch of order records goes in, four workers process the records, and a report comes out. Three of the records are malformed, each in a different way. A real batch runner cannot assume that its input is clean.

```zig
const std = @import("std");

/// The batch. It is a `const`, not stdin. Thus CI checks the same bytes that
/// the chapter shows. Three records are malformed on purpose, each in a
/// different way, because a batch runner must handle bad input.
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

/// The result for one record. Each worker writes only the slot that it
/// claimed. Thus this struct needs no lock.
const Result = struct {
    id: u32 = 0,
    total: u64 = 0,
    failure: ?[]const u8 = null,
};

/// The only state that the workers really share: the biggest order in the
/// batch and the record that it came from. The two fields must agree with each
/// other, and a single atomic cannot keep two fields in agreement.
const Largest = struct {
    value: u64 = 0,
    index: usize = 0,
};

/// Change one record into a `Result`. The function uses no `Io`, allocator or
/// shared state. Thus you can read it and test it alone.
fn parseOrder(line: []const u8) Result {
    var fields = std.mem.splitScalar(u8, line, ',');
    const id_text = fields.next() orelse return .{ .failure = "no id" };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return .{ .failure = "bad id" };

    // The function reads the id before other parts can fail. Thus each line of
    // the report names its record.
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

/// Claim records until none remain. Each worker runs this same function. The
/// scheduler decides which records each worker gets.
fn worker(
    io: std.Io,
    records: []const []const u8,
    results: []Result,
    next: *std.atomic.Value(usize),
    largest: *Largest,
    mutex: *std.Io.Mutex,
) void {
    while (true) {
        // One atomic add gives one record to a worker. `fetchAdd` returns the
        // value from before the add. Thus no two workers can claim one index.
        const index = next.fetchAdd(1, .monotonic);
        if (index >= records.len) return;

        const result = parseOrder(records[index]);
        results[index] = result;
        if (result.failure != null) continue;

        mutex.lock(io) catch return;
        defer mutex.unlock(io);

        // The tie break on the index is necessary. Without it, if two records
        // have equal value, the answer is the record from the first worker.
        // Then the program can print a different line on a different
        // computer.
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

    // The program divides the batch into records one time, in sequence,
    // before a worker starts. The slices that it gives to the workers make the
    // remainder parallel.
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

    // Use `group.async`, not `group.concurrent`. These tasks all complete
    // without help. Thus an `Io` that runs one inline, because its pool is
    // busy, is still correct. A task that you intend to cancel needs
    // `concurrent`.
    var group: std.Io.Group = .init;
    for (0..worker_count) |_| {
        group.async(io, worker, .{ io, records, results[0..count], &next, &largest, &mutex });
    }
    try group.await(io);

    // The program prints after all workers are done. It prints in record
    // order, not in completion order. The work runs concurrently, but the
    // report has a fixed order.
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

*CI builds and runs this program natively. wasm32-wasi has a single thread. Thus each worker runs inline, and the program behaves like a plain for loop. (`03-standard-library.batch-runner`)*

The program has three items of state that the workers use. The program protects each item in a different way.

## Three kinds of state, three different answers

The results are one slot for each record.

```zig
/// The result for one record. Each worker writes only the slot that it
/// claimed. Thus this struct needs no lock.
const Result = struct {
    id: u32 = 0,
    total: u64 = 0,
    failure: ?[]const u8 = null,
};
```

*Quoted from the source: `Result` from `snippets/03-standard-library/batch-runner.zig`.*

Each worker writes only the slot of the record that it claimed. Thus two workers never write the same bytes, and the slots need no lock and no atomic. This is the cheapest way to share state, and the first way to try.

The work index is a single number that each worker increments. It is one machine word, and one operation changes it. It does not have to agree with a different value. Thus an atomic is sufficient for the work index.

The largest order in the batch is the third kind of state.

```zig
/// The only state that the workers really share: the biggest order in the
/// batch and the record that it came from. The two fields must agree with each
/// other, and a single atomic cannot keep two fields in agreement.
const Largest = struct {
    value: u64 = 0,
    index: usize = 0,
};
```

*Quoted from the source: `Largest` from `snippets/03-standard-library/batch-runner.zig`.*

The struct has two fields that must agree with each other. One is a value that belongs to an index. The other is an index that belongs to a value.

Atomic operations cannot keep that pair consistent. The end of [Atomics](https://www.ziglang.in/learn/concurrency/atomics/) explains why. Thus the pair needs a mutex, and the pair is the only item in the program that needs one.

## Claim work with one atomic add

```zig
/// Claim records until none remain. Each worker runs this same function. The
/// scheduler decides which records each worker gets.
fn worker(
    io: std.Io,
    records: []const []const u8,
    results: []Result,
    next: *std.atomic.Value(usize),
    largest: *Largest,
    mutex: *std.Io.Mutex,
) void {
    while (true) {
        // One atomic add gives one record to a worker. `fetchAdd` returns the
        // value from before the add. Thus no two workers can claim one index.
        const index = next.fetchAdd(1, .monotonic);
        if (index >= records.len) return;

        const result = parseOrder(records[index]);
        results[index] = result;
        if (result.failure != null) continue;

        mutex.lock(io) catch return;
        defer mutex.unlock(io);

        // The tie break on the index is necessary. Without it, if two records
        // have equal value, the answer is the record from the first worker.
        // Then the program can print a different line on a different
        // computer.
        if (result.total > largest.value or
            (result.total == largest.value and index < largest.index))
        {
            largest.* = .{ .value = result.total, .index = index };
        }
    }
}
```

*Quoted from the source: `worker` from `snippets/03-standard-library/batch-runner.zig`.*

Each worker runs the same function, and the workers compete for records.

`fetchAdd` returns the value from before the addition. Thus each worker gets an index that no other worker can get. That is how the program gives work to the workers.

When the returned index is past the end, the worker returns. Then the batch is done.

No code counts or divides the batch at the start. Thus no worker is idle because its share was the easy half.

## The parser knows nothing about concurrency

```zig
/// Change one record into a `Result`. The function uses no `Io`, allocator or
/// shared state. Thus you can read it and test it alone.
fn parseOrder(line: []const u8) Result {
    var fields = std.mem.splitScalar(u8, line, ',');
    const id_text = fields.next() orelse return .{ .failure = "no id" };
    const id = std.fmt.parseInt(u32, id_text, 10) catch return .{ .failure = "bad id" };

    // The function reads the id before other parts can fail. Thus each line of
    // the report names its record.
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
```

*Quoted from the source: `parseOrder` from `snippets/03-standard-library/batch-runner.zig`.*

`parseOrder` takes no `Io` and no allocator. It uses no shared state, and it does not know that concurrent work occurs. You can read it and test it alone.

A mistake in the concurrency cannot make the parse wrong. When this part has no concurrency, the full program is much easier to review. The networking chapters keep protocol code away from sockets for the same reason.

## The tie break is necessary

Look again at the comparison inside the lock.

A plain "greater than" is sufficient to find the largest value. It is not sufficient to find the value **the same way two times**.

If two records have equal value, the answer is the record from the worker that got there first. That worker changes with the computer, with the run, and with the load on the computer.

The tie break on the index gives the reduction a total order. Thus the result does not depend on the worker that arrived first.

Each reduction that workers share needs this rule. The reduction can find a maximum, a minimum, a first match or a best candidate. If two inputs can tie, something other than the order of arrival must decide between them.

## The run is concurrent, the report is not

The program prints nothing until all of the workers are done. Then the report reads the results in record order, not in the order that the workers made them.

This is intentional. Each program on this site runs each night, and CI compares its output with a recorded file. If the output depended on the scheduler, no person could check it.

The same rule applies outside this site. Sometimes the result of a concurrent program depends on the order in which its tasks ran. Then you cannot test the program, and you do not see when it starts to give wrong answers.

Make the result independent of the scheduler. Then you can change how the work runs later, and the result does not change.

## `group.async`, not `group.concurrent`

The workers start on a `Group`, and the selected function is important.

`group.async` can run a task inline when the pool is busy. That is correct for these workers. Each worker completes without help, thus a worker on the thread that calls `group.async` still completes its work.

`group.concurrent` promises a separate unit of concurrency. It returns an error when it cannot give one.

Use `concurrent` when a task possibly does not complete without help. In practice, this means each task that you intend to cancel. [Cancellation](https://www.ziglang.in/learn/concurrency/cancellation/) shows what goes wrong if you do not. It also shows how the problem occurred in the CI of this guide.

## What actually happened

I added instrumentation to a copy of this program. The copy recorded which thread claimed each record. I ran it on a computer with twelve cores.

All twelve records went to one thread. That result occurred on each run, with each setting for the work per record.

The first worker starts before the second worker exists. Twelve records is much too little work. The first worker is already done when the second worker starts.

A larger batch changes the result. At two hundred records, the same binary gives a different answer on each run: one thread, then three, then two. The runs were seconds apart on a computer with no other load. At five thousand records, the result is four threads each time.

Thus, **the work index makes the batch safe to share, but it does not make the batch parallel**. The safety comes from the structure, thus it is true at all sizes. The work runs in parallel only when the work is sufficient to keep the first worker busy while the other workers start.

This is also why the report does not depend on the scheduler. The same program, with the same input on the same computer, divided the work differently two seconds apart. A report that showed threads would be wrong when you read it.

## When this shape is the wrong one

A work index is correct for a fixed batch that you know at the start. For other work, use a different shape:

- For work that arrives while the program runs, use [`Io.Queue`](https://www.ziglang.in/learn/concurrency/queues/). Producers and consumers run at the same time. The capacity of the queue limits how far the producers can go ahead of the consumers.
- For work with a deadline, put [Select](https://www.ziglang.in/learn/concurrency/select/) around the group. Then cancel the work that is not complete.
- For work where each job is a network round trip, use many more workers than cores. The workers block for most of their time, and they do not compute.

Next: [Choose an Io](https://www.ziglang.in/learn/concurrency/choosing-an-io/) explains the choice that this program makes in one line. The other chapters assume that choice.
