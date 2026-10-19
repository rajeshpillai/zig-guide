//! title: A Batch Job Runner
//! native
//! Four workers over one batch of records. The program has an atomic work
//! index and one private result slot for each record. A mutex protects the
//! only state that the workers really share. Native, because `wasm32-wasi`
//! has one thread. On it, each worker runs inline, and the program is only a
//! `for` loop.

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
