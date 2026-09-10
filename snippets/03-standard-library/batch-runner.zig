//! title: A Batch Job Runner
//! native
//! Four workers over one batch of records: an atomic work index, one private
//! result slot per record, and a mutex over the only state that is genuinely
//! shared. Native because `wasm32-wasi` has one thread, so every worker would
//! run inline and this would be a `for` loop wearing a costume.

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
