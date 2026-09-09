//! title: Breadth-First Search on a Grid
//! Fewest moves from one cell to another, with the distance field printed as
//! the frontier expands. The program runs the same search twice, once marking
//! a cell seen as it goes into the queue and once as it comes out, and counts
//! what the second one costs. Every table here is output CI diffed.

const std = @import("std");

/// The grid, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. `#` is a wall, `.` is open, `S` is the start and `T` is the target.
/// The parser below reads it the way it would read a real file.
const input =
    \\S.....#......
    \\......#...#..
    \\......#..#.#.
    \\......#...#..
    \\..###.#......
    \\..#...#......
    \\..#.#####....
    \\..#..........
    \\..#.........T
;

/// Where a cell is. Rows and columns are `usize` because they index.
const Pos = struct { r: usize, c: usize };

/// One of the four moves, as a pair of signed offsets.
///
/// `i8` and not `usize`. Moving up from row 0 has to produce something that is
/// recognisably off the grid. Subtracting one from an unsigned row of zero
/// does not: it overflows, which panics in a safety build and is undefined
/// behaviour in the release build this page ships. The offsets stay signed
/// until the bounds check has passed.
const Step = struct { dr: i8, dc: i8, name: []const u8 };

/// Up, down, left, right. The order decides nothing for the distances and
/// everything for the path a depth-first walk picks.
const moves = [4]Step{
    .{ .dr = -1, .dc = 0, .name = "up" },
    .{ .dr = 1, .dc = 0, .name = "down" },
    .{ .dr = 0, .dc = -1, .name = "left" },
    .{ .dr = 0, .dc = 1, .name = "right" },
};

/// A rectangle of characters, addressed by row and column.
const Grid = struct {
    cells: []const u8,
    rows: usize,
    cols: usize,

    fn count(g: Grid) usize {
        return g.rows * g.cols;
    }

    fn index(g: Grid, p: Pos) usize {
        return p.r * g.cols + p.c;
    }

    fn at(g: Grid, i: usize) Pos {
        return .{ .r = i / g.cols, .c = i % g.cols };
    }

    fn char(g: Grid, i: usize) u8 {
        return g.cells[i];
    }

    fn isOpen(g: Grid, i: usize) bool {
        return g.cells[i] != '#';
    }

    /// The cell one move from `p`, or null when that move leaves the grid.
    ///
    /// The arithmetic happens in `isize`, where -1 is a value like any other.
    /// Both bounds are checked before the result is narrowed back to `usize`,
    /// so nothing subtracts one from a zero-valued index anywhere in the file.
    fn step(g: Grid, p: Pos, m: Step) ?Pos {
        const r = @as(isize, @intCast(p.r)) + m.dr;
        const c = @as(isize, @intCast(p.c)) + m.dc;
        if (r < 0 or c < 0) return null;
        if (r >= @as(isize, @intCast(g.rows)) or c >= @as(isize, @intCast(g.cols))) return null;
        return .{ .r = @intCast(r), .c = @intCast(c) };
    }

    fn find(g: Grid, wanted: u8) !usize {
        return std.mem.findScalar(u8, g.cells, wanted) orelse error.MissingCell;
    }
};

/// Read the grid out of a reader, one line per row.
///
/// Taking a `*std.Io.Reader` rather than the string is the same discipline the
/// networking chapters use for protocols. Point it at a file on a judge and
/// not a line of it changes. Rows of different lengths are rejected here
/// rather than at the first index that walks off the end of one.
fn readGrid(reader: *std.Io.Reader, out: []u8) !Grid {
    var rows: usize = 0;
    var cols: usize = 0;
    var used: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        if (rows == 0) cols = line.len;
        if (line.len != cols) return error.RaggedGrid;
        if (used + line.len > out.len) return error.GridTooBig;
        @memcpy(out[used..][0..line.len], line);
        used += line.len;
        rows += 1;
    }
    if (rows == 0) return error.EmptyGrid;
    return .{ .cells = out[0..used], .rows = rows, .cols = cols };
}

/// One waiting cell: where it is, and how far it is from the start.
///
/// Carrying the distance in the queue rather than reading it out of the
/// distance array keeps the two searches below comparable: the only thing
/// that moves between them is where a cell is marked.
const Entry = struct { cell: usize, dist: u32 };

/// A queue that is an array, a read index and a write index.
///
/// `pop` moves `head` forward and never reclaims the slot behind it, so the
/// number of slots this needs is the number of pushes over the whole search
/// and not the most it ever held at once. The two searches below disagree
/// about that number.
const Queue = struct {
    slots: []Entry,
    head: usize = 0,
    tail: usize = 0,

    fn push(q: *Queue, e: Entry) !void {
        if (q.tail == q.slots.len) return error.QueueFull;
        q.slots[q.tail] = e;
        q.tail += 1;
    }

    fn pop(q: *Queue) ?Entry {
        if (q.head == q.tail) return null;
        defer q.head += 1;
        return q.slots[q.head];
    }

    fn waiting(q: Queue) usize {
        return q.tail - q.head;
    }
};

/// What a search cost.
const Cost = struct {
    pushes: usize = 0,
    pops: usize = 0,
    repeats: usize = 0,
    longest: usize = 0,
};

/// Fewest moves from `start` to every reachable cell.
///
/// A cell is marked the moment it is pushed. Every push therefore takes a cell
/// that has never been pushed before, which caps the pushes at the number of
/// cells and lets the queue be sized exactly once, up front.
///
/// The distances come out right because the queue hands cells back in the
/// order they went in. All the cells at distance `d` are pushed before any at
/// `d + 1`, so they come out first as well, and the first time a cell is
/// reached is by a route as short as any other.
fn bfsMarkOnPush(
    g: Grid,
    start: usize,
    dist: []?u32,
    from: []?usize,
    seen: []bool,
    slots: []Entry,
    cost: *Cost,
) !void {
    @memset(dist, null);
    @memset(from, null);
    @memset(seen, false);

    var q: Queue = .{ .slots = slots };
    seen[start] = true;
    dist[start] = 0;
    try q.push(.{ .cell = start, .dist = 0 });
    cost.pushes += 1;

    while (q.pop()) |e| {
        cost.pops += 1;
        cost.longest = @max(cost.longest, q.waiting());
        for (moves) |m| {
            const next = g.step(g.at(e.cell), m) orelse continue;
            const j = g.index(next);
            if (!g.isOpen(j) or seen[j]) continue;
            seen[j] = true;
            dist[j] = e.dist + 1;
            from[j] = e.cell;
            try q.push(.{ .cell = j, .dist = e.dist + 1 });
            cost.pushes += 1;
        }
    }
}

/// The same search, marking a cell when it comes out of the queue.
///
/// The mark moves down two lines and the answers do not change. A cell now
/// enters the queue once for every neighbour that expands before the cell is
/// first popped, so the pushes are bounded by the moves between cells rather
/// than by the cells. The skip on the way out is what keeps the result
/// correct, and it is the only reason the extra copies are harmless.
fn bfsMarkOnPop(
    g: Grid,
    start: usize,
    dist: []?u32,
    seen: []bool,
    slots: []Entry,
    cost: *Cost,
) !void {
    @memset(dist, null);
    @memset(seen, false);

    var q: Queue = .{ .slots = slots };
    try q.push(.{ .cell = start, .dist = 0 });
    cost.pushes += 1;

    while (q.pop()) |e| {
        cost.pops += 1;
        cost.longest = @max(cost.longest, q.waiting());
        if (seen[e.cell]) {
            cost.repeats += 1;
            continue;
        }
        seen[e.cell] = true;
        dist[e.cell] = e.dist;
        for (moves) |m| {
            const next = g.step(g.at(e.cell), m) orelse continue;
            const j = g.index(next);
            if (!g.isOpen(j) or seen[j]) continue;
            try q.push(.{ .cell = j, .dist = e.dist + 1 });
            cost.pushes += 1;
        }
    }
}

/// The distances again, from repeated relaxation instead of a queue.
///
/// Sweep the whole grid, lower any cell that a neighbour can improve, and
/// repeat until a sweep changes nothing. It shares no code with the searches
/// above, so agreeing with it is worth something. It also costs a sweep per
/// level, which is the price of not knowing what order to look in.
fn relaxDistances(g: Grid, start: usize, dist: []?u32, sweeps: *usize, looks: *usize) void {
    @memset(dist, null);
    dist[start] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        sweeps.* += 1;
        for (0..g.count()) |i| {
            if (!g.isOpen(i)) continue;
            for (moves) |m| {
                looks.* += 1;
                const next = g.step(g.at(i), m) orelse continue;
                const j = g.index(next);
                if (!g.isOpen(j)) continue;
                const near = dist[j] orelse continue;
                if (dist[i] == null or dist[i].? > near + 1) {
                    dist[i] = near + 1;
                    changed = true;
                }
            }
        }
    }
}

/// The first path a depth-first walk finds, in the move order above.
///
/// It marks a cell seen on the way in and never unmarks it, so it visits each
/// cell once and returns a path rather than the shortest path. `path` holds
/// the cells still on the stack, which is the route back to the start.
fn dfsFirstPath(
    g: Grid,
    at: usize,
    target: usize,
    seen: []bool,
    path: []usize,
    len: *usize,
) bool {
    seen[at] = true;
    path[len.*] = at;
    len.* += 1;
    if (at == target) return true;
    for (moves) |m| {
        const next = g.step(g.at(at), m) orelse continue;
        const j = g.index(next);
        if (!g.isOpen(j) or seen[j]) continue;
        if (dfsFirstPath(g, j, target, seen, path, len)) return true;
    }
    len.* -= 1;
    return false;
}

/// Walk `from` back to the start, filling `path` with the route forwards.
fn tracePath(target: usize, from: []const ?usize, path: []usize) usize {
    var len: usize = 0;
    var cur: ?usize = target;
    while (cur) |c| : (cur = from[c]) {
        path[len] = c;
        len += 1;
    }
    std.mem.reverse(usize, path[0..len]);
    return len;
}

/// Right-align a value in a cell of `width` characters.
///
/// `{d:>4}` would be shorter, and it prints a `+` in front of a non-negative
/// signed integer as soon as a width is given. Formatting the digits first and
/// padding them keeps the columns readable.
fn writeCell(out: *std.Io.Writer, value: i64, width: usize) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The column numbers, above whatever grid comes next.
fn writeHeader(out: *std.Io.Writer, g: Grid) !void {
    try out.writeAll("      ");
    for (0..g.cols) |c| try writeCell(out, @intCast(c), 3);
    try out.writeByte('\n');
}

/// The grid as characters, one row per line.
fn writeGrid(out: *std.Io.Writer, g: Grid, overlay: []const u8) !void {
    try writeHeader(out, g);
    for (0..g.rows) |r| {
        try out.print("  r{d}  ", .{r});
        for (0..g.cols) |c| {
            const i = g.index(.{ .r = r, .c = c });
            try out.writeAll("  ");
            try out.writeByte(if (overlay.len > 0 and overlay[i] != 0) overlay[i] else g.char(i));
        }
        try out.writeByte('\n');
    }
}

/// The distance field, hiding anything further out than `limit`.
///
/// A wall prints as `##` and a cell with no distance yet prints as a dot, so
/// the reachable region grows out of the picture rather than being described.
fn writeField(out: *std.Io.Writer, g: Grid, dist: []const ?u32, limit: u32) !void {
    try writeHeader(out, g);
    for (0..g.rows) |r| {
        try out.print("  r{d}  ", .{r});
        for (0..g.cols) |c| {
            const i = g.index(.{ .r = r, .c = c });
            if (!g.isOpen(i)) {
                try out.writeAll(" ##");
            } else if (dist[i]) |d| {
                if (d > limit) try out.writeAll("  .") else try writeCell(out, d, 3);
            } else {
                try out.writeAll("  .");
            }
        }
        try out.writeByte('\n');
    }
}

/// One row of the cost table.
fn writeCostRow(out: *std.Io.Writer, label: []const u8, cost: Cost) !void {
    try out.print("  {s: <8}", .{label});
    try writeCell(out, @intCast(cost.pushes), 6);
    try writeCell(out, @intCast(cost.pops), 6);
    try writeCell(out, @intCast(cost.repeats), 13);
    try writeCell(out, @intCast(cost.longest), 14);
    try out.writeByte('\n');
}

/// `bfsMarkOnPush` with the field printed each time the frontier moves out one
/// step past a distance in `snapshots`.
///
/// Kept separate so the function above stays the shape you would paste into a
/// solution. The run below checks that the two agree rather than trusting it.
fn traceBfs(
    out: *std.Io.Writer,
    g: Grid,
    start: usize,
    dist: []?u32,
    seen: []bool,
    slots: []Entry,
    snapshots: []const u32,
) !void {
    @memset(dist, null);
    @memset(seen, false);

    var q: Queue = .{ .slots = slots };
    seen[start] = true;
    dist[start] = 0;
    try q.push(.{ .cell = start, .dist = 0 });

    var level: u32 = 0;
    var ordered = true;
    while (q.pop()) |e| {
        if (e.dist < level) ordered = false;
        if (e.dist > level) {
            if (std.mem.findScalar(u32, snapshots, level) != null) {
                try out.print(
                    "  distance {d} is out of the queue, and the {d} cells at distance {d} are in it\n",
                    .{ level, q.waiting() + 1, e.dist },
                );
                try writeField(out, g, dist, e.dist);
                try out.writeByte('\n');
            }
            level = e.dist;
        }
        for (moves) |m| {
            const next = g.step(g.at(e.cell), m) orelse continue;
            const j = g.index(next);
            if (!g.isOpen(j) or seen[j]) continue;
            seen[j] = true;
            dist[j] = e.dist + 1;
            try q.push(.{ .cell = j, .dist = e.dist + 1 });
        }
    }
    try out.print("  the queue never handed back a shorter distance -> {}\n\n", .{ordered});
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var cell_storage: [512]u8 = undefined;
    const g = try readGrid(&reader, &cell_storage);
    const n = g.count();

    const start = try g.find('S');
    const target = try g.find('T');

    try out.print(
        "{d} rows by {d} columns, {d} cells, start at r{d}c{d}, target at r{d}c{d}\n",
        .{ g.rows, g.cols, n, g.at(start).r, g.at(start).c, g.at(target).r, g.at(target).c },
    );
    try writeGrid(out, g, &.{});
    try out.writeByte('\n');

    // Where the four moves land from the corner, and what stops two of them.
    try out.writeAll("the four moves from the start, in signed arithmetic\n");
    try out.writeAll("  move    dr  dc     r     c  on the grid\n");
    const corner = g.at(start);
    for (moves) |m| {
        try out.print("  {s: <6}", .{m.name});
        try writeCell(out, m.dr, 4);
        try writeCell(out, m.dc, 4);
        try writeCell(out, @as(i64, @intCast(corner.r)) + m.dr, 6);
        try writeCell(out, @as(i64, @intCast(corner.c)) + m.dc, 6);
        try out.print("  {s}\n", .{if (g.step(corner, m) == null) "no" else "yes"});
    }
    try out.writeByte('\n');

    var dist: [512]?u32 = undefined;
    var check: [512]?u32 = undefined;
    var from: [512]?usize = undefined;
    var seen: [512]bool = undefined;
    var slots: [2048]Entry = undefined;
    var path: [512]usize = undefined;
    var overlay: [512]u8 = undefined;

    // The frontier, printed twice on the way out and once at the end.
    try out.writeAll("the distance field as the frontier expands\n");
    const snapshots = [_]u32{ 4, 17 };
    try traceBfs(out, g, start, dist[0..n], seen[0..n], slots[0..n], &snapshots);

    var push_cost: Cost = .{};
    try bfsMarkOnPush(g, start, dist[0..n], from[0..n], seen[0..n], slots[0..n], &push_cost);
    try out.writeAll("  the finished field\n");
    try writeField(out, g, dist[0..n], std.math.maxInt(u32));
    try out.writeByte('\n');

    // How many cells sit at each distance, and how many the walls seal off.
    var open_cells: usize = 0;
    var reached: usize = 0;
    var deepest: u32 = 0;
    for (0..n) |i| {
        if (!g.isOpen(i)) continue;
        open_cells += 1;
        if (dist[i]) |d| {
            reached += 1;
            deepest = @max(deepest, d);
        }
    }

    var per_distance: [64]usize = @splat(0);
    for (0..n) |i| {
        if (dist[i]) |d| per_distance[d] += 1;
    }

    try out.writeAll("how many cells sit at each distance\n");
    var low: u32 = 0;
    while (low <= deepest) : (low += 16) {
        const high = @min(deepest, low + 15);
        try out.writeAll("  distance");
        for (low..high + 1) |d| try writeCell(out, @intCast(d), 3);
        try out.writeAll("\n  cells   ");
        for (low..high + 1) |d| try writeCell(out, @intCast(per_distance[d]), 3);
        try out.writeByte('\n');
    }
    try out.print(
        "  {d} open cells, {d} reached in at most {d} moves, {d} sealed off by walls\n\n",
        .{ open_cells, reached, deepest, open_cells - reached },
    );

    // The route itself, drawn back through the parent of each cell.
    const path_len = tracePath(target, from[0..n], &path);
    @memset(overlay[0..n], 0);
    for (path[0..path_len]) |i| overlay[i] = 'o';
    overlay[start] = 'S';
    overlay[target] = 'T';
    try out.print(
        "the shortest route: {d} moves through {d} cells\n",
        .{ dist[target].?, path_len },
    );
    try writeGrid(out, g, overlay[0..n]);
    try out.writeByte('\n');

    // The same target found by going deep instead of wide.
    var dfs_len: usize = 0;
    @memset(seen[0..n], false);
    if (!dfsFirstPath(g, start, target, seen[0..n], &path, &dfs_len)) return error.NoPath;
    @memset(overlay[0..n], 0);
    for (path[0..dfs_len]) |i| overlay[i] = 'o';
    overlay[start] = 'S';
    overlay[target] = 'T';
    try out.print(
        "the first route a depth-first walk finds: {d} moves, against {d}\n",
        .{ dfs_len - 1, dist[target].? },
    );
    try writeGrid(out, g, overlay[0..n]);
    try out.writeByte('\n');

    // The queue bill, both ways round.
    var pop_cost: Cost = .{};
    try bfsMarkOnPop(g, start, check[0..n], seen[0..n], &slots, &pop_cost);

    try out.writeAll("what each marking rule costs on this grid\n");
    try out.writeAll("  marked  pushes  pops  repeat pops  most waiting\n");
    try writeCostRow(out, "on push", push_cost);
    try writeCostRow(out, "on pop", pop_cost);
    try out.print(
        "  {d} cells reached out of {d}, so marking on push never fills a queue of {d}\n",
        .{ reached, open_cells, n },
    );

    var tight: Cost = .{};
    if (bfsMarkOnPop(g, start, check[0..n], seen[0..n], slots[0..n], &tight)) {
        try out.print("  marking on pop also fits {d} slots\n", .{n});
    } else |err| {
        try out.print(
            "  marking on pop in a queue of {d} slots: {s} after {d} pushes\n",
            .{ n, @errorName(err), tight.pushes },
        );
    }
    try bfsMarkOnPop(g, start, check[0..n], seen[0..n], &slots, &pop_cost);
    try out.print(
        "  same distance to the target either way, {d} and {d} -> {}\n\n",
        .{ dist[target].?, check[target].?, std.mem.eql(?u32, dist[0..n], check[0..n]) },
    );

    // A second implementation that shares nothing with the first.
    var sweeps: usize = 0;
    var looks: usize = 0;
    relaxDistances(g, start, check[0..n], &sweeps, &looks);
    try out.print(
        "repeated relaxation agrees on every cell -> {}\n",
        .{std.mem.eql(?u32, dist[0..n], check[0..n])},
    );
    try out.print(
        "  {d} sweeps of the whole grid, {d} neighbours looked at, against {d} from the queue\n",
        .{ sweeps, looks, push_cost.pops * 4 },
    );

    try out.flush();
}
