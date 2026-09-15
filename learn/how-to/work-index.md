# Recipe: An Atomic Work Index

> Dynamic load balancing with fetchAdd instead of locks or chunking.

## The problem

Static chunking (one slice piece per thread) balances load only when every
item costs the same. If item 7 takes a hundred times longer than item 8,
the thread that owns item 7's chunk finishes last while the others sit
idle. You want threads to pull the next job when they are free, like
workers taking tickets from a dispenser.

A mutex around a `next_job` counter works, but the counter is the entire
critical section. Atomics do the same job without a lock.

## The plan

1. Share two atomics: `next`, the index of the next unclaimed job, and
   `total`, the running result.
2. Each worker loops: claim an index with `fetchAdd(1, .monotonic)`, stop
   when it is past the end, otherwise process the job and fold the result
   into `total` with another `fetchAdd`.
3. Spawn the workers, `join` them, read the total.

```zig
const std = @import("std");

const jobs = blk: {
    var j: [100]u64 = undefined;
    for (&j, 1..) |*x, i| x.* = i;
    break :blk j;
};

fn worker(next: *std.atomic.Value(usize), total: *std.atomic.Value(u64)) void {
    while (true) {
        // fetchAdd hands out each index exactly once, no lock involved.
        // Two threads can race here and still never get the same job.
        const i = next.fetchAdd(1, .monotonic);
        if (i >= jobs.len) return;

        const result = jobs[i] * jobs[i]; // the "work"
        _ = total.fetchAdd(result, .monotonic);
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var next = std.atomic.Value(usize).init(0);
    var total = std.atomic.Value(u64).init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &next, &total });
    }
    for (threads) |t| t.join();

    // Threads finished in some order, but every job ran exactly once, so
    // the sum is the same on every run.
    try out.print("sum of squares 1..100: {d}\n", .{total.load(.monotonic)});

    try out.flush();
}
```

*Built and run natively by CI. wasm32-wasi is single-threaded, so std.Thread.spawn does not compile for it at all. (`06-cookbook.work-index`)*

## Why fetchAdd cannot double-serve a job

`fetchAdd` is a single indivisible read-modify-write: it returns the old
value and stores the incremented one, and no other thread can slip in
between. Two threads racing on the same counter get two different
indices, always. That property, not speed, is the reason to use an atomic
here; the lock-free part is a bonus.

Both atomics use `.monotonic` ordering because each one is independent:
no thread reads `total` until after `join`, and `join` already provides
the visibility guarantee. The moment one atomic is supposed to publish
writes to *other* memory, ordering gets subtle; keep counters independent
and the simplest ordering stays correct.

## When threads out-claim the work

Every worker exits by claiming an index past the end. With 4 threads, up
to 4 claims overshoot; the counter ends beyond `jobs.len`. That is
harmless and normal. Do not reuse the counter's final value as "jobs
done"; count completions separately if you need the number.

## Variations

- **Batch claiming:** `fetchAdd(16, ...)` hands out sixteen jobs per
  claim, cutting contention on the counter when jobs are tiny.
- **Results per job:** when each job produces data rather than a number
  to fold, write to `results[i]`; index ownership makes the slot private,
  so the write needs no lock.
- **Compare with chunking:** the [parallel sum](https://www.ziglang.in/learn/how-to/parallel-sum/)
  recipe is the static version; prefer it when per-item cost is uniform,
  since it touches the shared counter zero times.
