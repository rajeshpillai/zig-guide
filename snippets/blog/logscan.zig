//! title: logscan
//! Reads an access log one line at a time and reports status codes, the
//! slowest endpoints, and the first 504. Give it a path and it reads that
//! file. Give it nothing and it writes a sample log first, which is what
//! happens when you press Run.

const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else blk: {
        try writeSampleLog(io, dir, "access.log", 50_000);
        break :blk "access.log";
    };

    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    // The whole program reads through these 64 KiB. A 2 GB file and a 2 KB
    // file use the same amount of memory for reading.
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);

    var report: Report = .init(gpa);
    defer report.deinit();
    try report.scan(&reader.interface);
    try report.print(out, buf.len);
}

/// One request, as the server logs it:
/// `2026-10-03T22:41:07Z GET /api/checkout 504 5000`
const Line = struct {
    time: []const u8,
    path: []const u8,
    status: u16,
    ms: u32,
};

/// Returns null for a line we cannot use. An aborted request is logged with
/// `-` where the milliseconds go, and one bad line must not stop the scan.
fn parseLine(text: []const u8) ?Line {
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    const time = fields.next() orelse return null;
    _ = fields.next() orelse return null; // the method: GET, POST
    const path = fields.next() orelse return null;
    const status = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    const ms = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    return .{ .time = time, .path = path, .status = status, .ms = ms };
}

const Endpoint = struct {
    requests: u64 = 0,
    total_ms: u64 = 0,
    max_ms: u32 = 0,

    fn average(e: Endpoint) u64 {
        return e.total_ms / e.requests;
    }
};

const Report = struct {
    gpa: std.mem.Allocator,
    lines: u64 = 0,
    bytes: u64 = 0,
    skipped: u64 = 0,
    /// One counter per possible status code. No allocation, no hashing.
    statuses: [600]u64 = @splat(0),
    endpoints: std.StringHashMapUnmanaged(Endpoint) = .empty,
    first_504: [20]u8 = undefined,
    first_504_len: usize = 0,

    fn init(gpa: std.mem.Allocator) Report {
        return .{ .gpa = gpa };
    }

    fn deinit(r: *Report) void {
        var keys = r.endpoints.keyIterator();
        while (keys.next()) |key| r.gpa.free(key.*);
        r.endpoints.deinit(r.gpa);
    }

    fn scan(r: *Report, in: *Io.Reader) !void {
        while (true) {
            const text = in.takeDelimiter('\n') catch |err| switch (err) {
                // A line longer than the buffer. Skip it and keep going.
                error.StreamTooLong => {
                    r.bytes += try in.discardDelimiterInclusive('\n');
                    r.lines += 1;
                    r.skipped += 1;
                    continue;
                },
                else => |e| return e,
            } orelse break;

            r.lines += 1;
            r.bytes += text.len + 1;
            const line = parseLine(text) orelse {
                r.skipped += 1;
                continue;
            };
            try r.add(line);
        }
    }

    fn add(r: *Report, line: Line) !void {
        if (line.status < r.statuses.len) r.statuses[line.status] += 1;

        if (line.status == 504 and r.first_504_len == 0) {
            const n = @min(line.time.len, r.first_504.len);
            @memcpy(r.first_504[0..n], line.time[0..n]);
            r.first_504_len = n;
        }

        const slot = try r.endpoints.getOrPut(r.gpa, line.path);
        if (!slot.found_existing) {
            // `line.path` points into the reader's buffer, and the next read
            // overwrites it. The map keeps the key, so it needs its own copy.
            slot.key_ptr.* = try r.gpa.dupe(u8, line.path);
            slot.value_ptr.* = .{};
        }
        const e = slot.value_ptr;
        e.requests += 1;
        e.total_ms += line.ms;
        e.max_ms = @max(e.max_ms, line.ms);
    }

    fn print(r: *Report, out: *Io.Writer, buffer_size: usize) !void {
        try out.print("read {d} lines, {d} bytes, through a {d}-byte buffer\n", .{ r.lines, r.bytes, buffer_size });
        try out.print("skipped {d} lines we could not parse\n\n", .{r.skipped});

        try out.print("status  requests\n", .{});
        for (r.statuses, 0..) |count, status| {
            if (count > 0) try out.print("  {d}  {d:>8}\n", .{ status, count });
        }

        const Row = struct { path: []const u8, e: Endpoint };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(r.gpa);
        var it = r.endpoints.iterator();
        while (it.next()) |kv| try rows.append(r.gpa, .{ .path = kv.key_ptr.*, .e = kv.value_ptr.* });

        // Slowest first. Ties go by name, so the order never depends on the
        // hash map's.
        std.mem.sort(Row, rows.items, {}, struct {
            fn lessThan(_: void, a: Row, b: Row) bool {
                if (a.e.average() != b.e.average()) return a.e.average() > b.e.average();
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.lessThan);

        try out.print("\nendpoint         requests  avg ms  max ms\n", .{});
        for (rows.items) |row| {
            try out.print("  {s:<15}{d:>8}{d:>8}{d:>8}\n", .{ row.path, row.e.requests, row.e.average(), row.e.max_ms });
        }

        if (r.first_504_len > 0) {
            try out.print("\nfirst 504 at {s}\n", .{r.first_504[0..r.first_504_len]});
        }
    }
};

/// A made-up hour of traffic from 22:00 to 23:00. From 22:40 the checkout
/// endpoint slows down and starts timing out, which is what the report has to
/// find. The seed is fixed, so every run writes the same file.
fn writeSampleLog(io: Io, dir: Io.Dir, name: []const u8, count: u32) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    const w = &writer.interface;

    var prng: std.Random.Xoshiro256 = .init(2026);
    const rand = prng.random();

    const paths = [_][]const u8{ "/", "/api/cart", "/api/checkout", "/api/search", "/login" };
    const base_ms = [_]u32{ 12, 40, 90, 60, 25 };

    for (0..count) |i| {
        const second: u32 = @intCast(i * 3600 / count);
        const minute = second / 60;
        // u32, not usize: usize is 64 bits here and 32 bits in wasm, and the
        // two widths draw different numbers from the same seed.
        const p = rand.uintLessThan(u32, paths.len);

        var status: u16 = if (rand.uintLessThan(u32, 100) < 2) 404 else 200;
        var ms = base_ms[p] + rand.uintLessThan(u32, base_ms[p]);
        if (p == 2 and minute >= 40) {
            ms *= 9;
            if (rand.uintLessThan(u32, 100) < 15) {
                status = 504;
                ms = 5000;
            }
        }

        try w.print("2026-10-03T22:{d:0>2}:{d:0>2}Z ", .{ minute, second % 60 });
        try w.print("{s} {s} {d} ", .{ if (p == 2) "POST" else "GET", paths[p], status });
        // About one request in a thousand was aborted, and has no time.
        if (rand.uintLessThan(u32, 1000) == 0) {
            try w.writeAll("-\n");
        } else {
            try w.print("{d}\n", .{ms});
        }
    }
    try w.flush();
}
