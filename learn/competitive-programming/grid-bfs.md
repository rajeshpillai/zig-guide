# Breadth-First Search on a Grid

> The distance field as the frontier grows, and the one line with a position that decides if a cell can enter the queue two times.

Breadth-first search, or BFS, is useful to find the shortest path on a grid when each move has the same cost.

The queue does not know about shortest paths. The shortest paths come from the order in which BFS visits cells:

- BFS processes the cells one move away before the cells two moves away.
- BFS processes the cells two moves away before the cells three moves away.

Because of this order, the first route that BFS finds to a cell is the shortest route to that cell.

The example uses a grid with 9 rows and 13 columns. The grid has walls, one cell that BFS cannot get to, a start position `S`, and a target `T`.

The program finds the shortest route from `S` to `T` and prints the distance field. It also shows a common mistake with the mark on a cell.

```zig
const std = @import("std");

/// The grid, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. `#` is a wall, `.` is open, `S` is the start and `T` is the target.
/// The parser below reads the grid in the same way that it reads a real file.
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

/// The position of a cell. Rows and columns are `usize` because they are
/// indices.
const Pos = struct { r: usize, c: usize };

/// One of the four moves, as a pair of signed offsets.
///
/// Use `i8`, not `usize`. A move up from row 0 must give a value that is
/// clearly off the grid. A subtraction of one from an unsigned row of zero
/// does not give such a value. The subtraction overflows. In a safety build,
/// the overflow causes a panic, and in the release build that this page ships,
/// it is undefined behaviour. The offsets stay signed until the bounds check
/// is complete.
const Step = struct { dr: i8, dc: i8, name: []const u8 };

/// Up, down, left, right. The order does not change the distances. But the
/// order decides which path a depth-first search finds.
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
    /// The arithmetic uses `isize`, where -1 is a normal value. The function
    /// checks the two bounds before it changes the result back to `usize`.
    /// Thus no code in the file subtracts one from an index with the value zero.
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
/// The function takes a `*std.Io.Reader` instead of the string. The
/// networking chapters use the same method for protocols. On a judge, give the
/// function a reader for a file. The function does not change. The function
/// rejects rows of different lengths here. Thus the error does not occur later,
/// at the first index that goes past the end of a row.
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

/// One cell in the queue: its position, and its distance from the start.
///
/// The queue holds the distance, and the searches do not read it from the
/// distance array. Thus the two searches below are comparable. The only
/// difference between them is the point where a cell gets its mark.
const Entry = struct { cell: usize, dist: u32 };

/// A queue that is an array, a read index and a write index.
///
/// `pop` moves `head` forward and never uses the slot behind it again. Thus
/// the queue needs one slot for each push in the full search. The largest
/// number of entries at one time is not the limit. The two searches below give
/// different numbers of pushes.
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

/// The cost of a search.
const Cost = struct {
    pushes: usize = 0,
    pops: usize = 0,
    repeats: usize = 0,
    longest: usize = 0,
};

/// The fewest moves from `start` to each cell that the search can get to.
///
/// The search marks a cell at the time of its push. Thus each push takes a
/// cell that no earlier push took. The number of cells is the limit for the
/// pushes, and you can choose the size of the queue one time, at the start.
///
/// The distances are correct because the queue gives back cells in the order
/// that they went in. The search pushes all the cells at distance `d` before a
/// cell at `d + 1`. Thus the cells at distance `d` also leave first. When the
/// search first gets to a cell, the route is as short as each other route.
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

/// The same search, but it marks a cell when the cell leaves the queue.
///
/// The mark moves from the push to the pop, and the answers do not change. Now a cell
/// enters the queue one time for each neighbour that expands before the first
/// pop of the cell. Thus the limit for the pushes is the number of moves
/// between cells, not the number of cells. The skip at the pop keeps the
/// result correct. The skip is the only reason that the extra copies are safe.
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
/// Sweep the full grid, and make the distance smaller for each cell that a
/// neighbour can improve. Do the sweep again until a sweep changes nothing.
/// This function shares no code with the searches above. Thus its agreement is
/// an independent check. It also costs one sweep for each level, because it
/// does not know the correct order of the cells.
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

/// The first path that a depth-first search finds, with the order of moves
/// above.
///
/// The search marks a cell as seen when it enters the cell, and it never
/// removes the mark. Thus it visits each cell one time, and it returns a path,
/// not the shortest path. `path` holds the cells that are still on the stack.
/// These cells are the route back to the start.
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

/// Follow `from` back to the start, and put the route in `path` from start to
/// target.
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
/// `{d:>4}` is shorter, but it prints a `+` before a non-negative signed
/// integer when you give a width. This function formats the digits first and
/// then adds the padding. Thus the columns are easy to read.
fn writeCell(out: *std.Io.Writer, value: i64, width: usize) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}", .{value});
    try out.splatByteAll(' ', width - text.len);
    try out.writeAll(text);
}

/// The column numbers, above the next grid.
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

/// The distance field, without the cells that are further away than `limit`.
///
/// A wall prints as `##`, and a cell with no distance prints as a dot. Thus
/// you can see the region that the search got to become larger in the picture.
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

/// `bfsMarkOnPush`, but it prints the field each time the frontier moves one
/// step past a distance in `snapshots`.
///
/// This function is separate, thus `bfsMarkOnPush` keeps the shape that you
/// can copy into a solution. The run below checks that the two functions agree.
/// It does not assume that they do.
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

    // The result of the four moves from the corner, and the reason that two
    // moves fail.
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

    // The frontier, printed two times while it grows and one time at the end.
    try out.writeAll("the distance field as the frontier expands\n");
    const snapshots = [_]u32{ 4, 17 };
    try traceBfs(out, g, start, dist[0..n], seen[0..n], slots[0..n], &snapshots);

    var push_cost: Cost = .{};
    try bfsMarkOnPush(g, start, dist[0..n], from[0..n], seen[0..n], slots[0..n], &push_cost);
    try out.writeAll("  the finished field\n");
    try writeField(out, g, dist[0..n], std.math.maxInt(u32));
    try out.writeByte('\n');

    // The number of cells at each distance, and the number of cells that the
    // walls isolate.
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

    // The route, from the parent of each cell back to the start.
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

    // The same target, with a depth-first search instead of a breadth-first
    // search.
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

    // The cost of the queue, for each search.
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

    // A second implementation that shares no code with the first.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.grid-bfs`)*

## BFS finds the shortest route

The shortest route in this grid has 24 moves:

```
the shortest route: 24 moves through 25 cells
        0  1  2  3  4  5  6  7  8  9 10 11 12
  r0    S  .  .  .  .  .  #  .  .  .  .  .  .
  r1    o  .  .  .  .  .  #  .  .  .  #  .  .
  r2    o  .  .  .  .  .  #  .  .  #  .  #  .
  r3    o  o  o  o  o  o  #  .  .  .  #  .  .
  r4    .  .  #  #  #  o  #  .  .  .  .  .  .
  r5    .  .  #  o  o  o  #  .  .  .  .  .  .
  r6    .  .  #  o  #  #  #  #  #  .  .  .  .
  r7    .  .  #  o  .  .  .  .  .  .  .  .  .
  r8    .  .  #  o  o  o  o  o  o  o  o  o  T
```

Without walls, the route from the top-left area to the target needs eight moves down and twelve moves to the right. That is 20 moves.

The walls make the route four moves longer. BFS still finds the smallest possible number of moves.

## Why DFS does not guarantee the shortest path

A depth-first search, or DFS, uses a stack instead of a queue. DFS follows one path as far as possible. Then DFS returns and tries a different direction.

```zig
/// The first path that a depth-first search finds, with the order of moves
/// above.
///
/// The search marks a cell as seen when it enters the cell, and it never
/// removes the mark. Thus it visits each cell one time, and it returns a path,
/// not the shortest path. `path` holds the cells that are still on the stack.
/// These cells are the route back to the start.
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
```

*Quoted from the source: `dfsFirstPath` from `snippets/23-competitive/grid-bfs.zig`.*

This DFS marks each cell when it enters the cell, and it stops when it first gets to the target. Thus DFS finds a valid route, but it does not guarantee the shortest route.

On the same grid:

```
the first route a depth-first walk finds: 68 moves, against 24
```

DFS finds a route of 68 moves, and BFS finds a route of 24 moves.

The figure draws the two routes on the same grid. Select a walk to compare them.

*Figure: The same grid twice: the BFS route reaches T in 24 moves, and the first route a depth-first walk finds takes 68. Select a walk, then press Next step. Both routes come from the program above.*

The result also depends on the order of the possible moves. A different order of `moves` can make DFS find a completely different route.

DFS is useful for many graph problems. But a normal DFS is not the correct tool when the problem asks for the fewest moves in an unweighted graph or grid.

## Move safely with usize coordinates

```zig
    /// The cell one move from `p`, or null when that move leaves the grid.
    ///
    /// The arithmetic uses `isize`, where -1 is a normal value. The function
    /// checks the two bounds before it changes the result back to `usize`.
    /// Thus no code in the file subtracts one from an index with the value zero.
    fn step(g: Grid, p: Pos, m: Step) ?Pos {
        const r = @as(isize, @intCast(p.r)) + m.dr;
        const c = @as(isize, @intCast(p.c)) + m.dc;
        if (r < 0 or c < 0) return null;
        if (r >= @as(isize, @intCast(g.rows)) or c >= @as(isize, @intCast(g.cols))) return null;
        return .{ .r = @intCast(r), .c = @intCast(c) };
    }
```

*Quoted from the source: `step` from `snippets/23-competitive/grid-bfs.zig`.*

The program stores rows and columns as `usize`, because they are array indices. This causes a problem for a move up or a move to the left.

For example, look at a cell in row 0. For that cell, the expression `p.r - 1` is not valid. A `usize` cannot hold `-1`. The subtraction underflows before the code can test if the result is inside the grid.

The same problem occurs for a move to the left from column 0.

The code prevents this problem, because it calculates the move with `isize`:

1. Calculate the move in `isize`. For example, a move up from `(0, 0)` gives `(-1, 0)`. The two coordinates are both valid `isize` values.
2. Check if the two coordinates are inside the grid.
3. After the bounds check, change the coordinates back to `usize`.

From `(0, 0)`, the four moves give:

```
  move    dr  dc     r     c  on the grid
  up      -1   0    -1     0  no
  down     1   0     1     0  yes
  left     0  -1     0    -1  no
  right    0   1     0     1  yes
```

From the top-left corner, a move up or a move to the left gives negative coordinates. The code rejects those moves before it accesses the array. A move down and a move to the right are valid.

A different method is to check before the subtraction. For example, test `if (p.r > 0)` before you calculate `p.r - 1`. The two methods are both valid.

Do not subtract 1 from a `usize` with the value zero and then try to check the result.

## Why BFS gives the shortest distance

```zig
/// The fewest moves from `start` to each cell that the search can get to.
///
/// The search marks a cell at the time of its push. Thus each push takes a
/// cell that no earlier push took. The number of cells is the limit for the
/// pushes, and you can choose the size of the queue one time, at the start.
///
/// The distances are correct because the queue gives back cells in the order
/// that they went in. The search pushes all the cells at distance `d` before a
/// cell at `d + 1`. Thus the cells at distance `d` also leave first. When the
/// search first gets to a cell, the route is as short as each other route.
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
```

*Quoted from the source: `bfsMarkOnPush` from `snippets/23-competitive/grid-bfs.zig`.*

BFS processes the grid one distance level at a time:

- The start cell has distance 0.
- The neighbours of the start cell have distance 1.
- Their unvisited neighbours have distance 2.
- The levels continue in the same way.

The queue keeps this order.

The search at a point before it is complete:

```
  distance 4 is out of the queue, and the 6 cells at distance 5 are in it
        0  1  2  3  4  5  6  7  8  9 10 11 12
  r0    0  1  2  3  4  5 ##  .  .  .  .  .  .
  r1    1  2  3  4  5  . ##  .  .  . ##  .  .
  r2    2  3  4  5  .  . ##  .  . ##  . ##  .
  r3    3  4  5  .  .  . ##  .  .  . ##  .  .
  r4    4  5 ## ## ##  . ##  .  .  .  .  .  .
  r5    5  . ##  .  .  . ##  .  .  .  .  .  .
  r6    .  . ##  . ## ## ## ## ##  .  .  .  .
  r7    .  . ##  .  .  .  .  .  .  .  .  .  .
  r8    .  . ##  .  .  .  .  .  .  .  .  .  .
```

The cells with the value 5 are the current frontier. BFS already processed each cell with a smaller distance.

The figure shows the same search for all distances. Press **Play**. Each ring is the set of cells at one distance, in the order the queue reaches them.

*Figure: A grid of 9 rows and 13 columns with walls. BFS numbers the cells by their distance from the top left corner, one distance at a time. The finished distance field from the program above, shown in the order the queue reaches each distance. Play runs through all of them.*

This order gives the guarantee of the shortest path:

1. BFS first gets to a cell from a different cell at distance `d`.
2. BFS gives the cell the distance `d + 1`.
3. A shorter route cannot occur later, because each cell that BFS processes later is at distance `d` or more.
4. Thus each later route to the same cell also has a length of `d + 1` or more.

Thus the first distance that BFS writes is already the shortest distance. BFS does not have to compare possible distances for the same cell again. BFS can mark the cell one time and never visit it again.

The completed distance field is:

```
  the finished field
        0  1  2  3  4  5  6  7  8  9 10 11 12
  r0    0  1  2  3  4  5 ## 29 28 29 30 31 30
  r1    1  2  3  4  5  6 ## 28 27 28 ## 30 29
  r2    2  3  4  5  6  7 ## 27 26 ##  . ## 28
  r3    3  4  5  6  7  8 ## 26 25 24 ## 26 27
  r4    4  5 ## ## ##  9 ## 25 24 23 24 25 26
  r5    5  6 ## 12 11 10 ## 24 23 22 23 24 25
  r6    6  7 ## 13 ## ## ## ## ## 21 22 23 24
  r7    7  8 ## 14 15 16 17 18 19 20 21 22 23
  r8    8  9 ## 15 16 17 18 19 20 21 22 23 24
```

The target has distance 24.

The cell at row 2, column 10 is still a dot. Walls are on all sides of the cell, thus BFS cannot get to it.

The grid has 95 open cells. BFS gets to 94 of them. BFS cannot get to the last one.

## Mark a cell when it enters the queue

A common BFS bug is to mark cells too late.

The correct version marks a cell as visited when it pushes the cell into the queue. Thus a different neighbour cannot push the same cell again.

Now move the mark to the point where BFS pops the cell.

```zig
/// The same search, but it marks a cell when the cell leaves the queue.
///
/// The mark moves from the push to the pop, and the answers do not change. Now a cell
/// enters the queue one time for each neighbour that expands before the first
/// pop of the cell. Thus the limit for the pushes is the number of moves
/// between cells, not the number of cells. The skip at the pop keeps the
/// result correct. The skip is the only reason that the extra copies are safe.
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
```

*Quoted from the source: `bfsMarkOnPop` from `snippets/23-competitive/grid-bfs.zig`.*

The final distances are still correct. But the search does work that is not necessary.

The program measures the difference:

```
what each marking rule costs on this grid
  marked  pushes  pops  repeat pops  most waiting
  on push     94    94            0             7
  on pop     143   143           49            12
  94 cells reached out of 95, so marking on push never fills a queue of 117
  marking on pop in a queue of 117 slots: QueueFull after 117 pushes
  same distance to the target either way, 24 and 24 -> true
```

With the mark on push, each cell that BFS can get to enters the queue exactly one time. BFS can get to 94 cells. Thus there are exactly 94 pushes and 94 pops.

With the mark on pop, a cell has no mark while it waits in the queue. During that time, more than one neighbour can find the cell. Each neighbour sees that the cell is not visited, and pushes the cell again. Thus the queue gets duplicates.

The second version does 143 pushes. Forty-nine pops are duplicates of cells that BFS already processed.

The result is still correct, because the code checks `seen` when it pops the cell. But the queue does much more work.

The correct rule is to mark a node when you enqueue it, not when you dequeue it.

## Why the mark on push is important

Look at a cell that BFS can get to from three neighbours.

With the mark on push:

1. The first neighbour finds the cell.
2. The first neighbour marks the cell.
3. The first neighbour pushes the cell.
4. Later, the other neighbours see that the cell already has a mark.
5. The other neighbours do not push the cell again.

The cell enters the queue one time.

With the mark on pop:

1. The first neighbour pushes the cell.
2. The cell still has no mark.
3. A second neighbour pushes the cell.
4. A third neighbour can also push the cell.
5. Later, the first copy leaves the queue and gets a mark.

At that time, the duplicates are already inside the queue.

On a grid, each cell has only a small number of neighbours. Thus a constant factor limits the extra work.

On a general graph, a vertex can have many neighbours. Then the number of pushes that are not necessary can become much larger.

## Choose the size of the queue

```zig
/// A queue that is an array, a read index and a write index.
///
/// `pop` moves `head` forward and never uses the slot behind it again. Thus
/// the queue needs one slot for each push in the full search. The largest
/// number of entries at one time is not the limit. The two searches below give
/// different numbers of pushes.
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
```

*Quoted from the source: `Queue` from `snippets/23-competitive/grid-bfs.zig`.*

The queue in this example uses a plain array and two indices. The queue does not use a position again after a pop. Thus the necessary storage depends on the total number of pushes, not only on the number of items that wait at one time.

With the correct mark, BFS pushes each cell that it can get to exactly one time. Thus a grid with `rows * columns` cells needs that number of queue slots or fewer. For this grid, `9 * 13 = 117`, thus 117 slots are sufficient.

The queue can allocate space for all cells one time. The queue never has to grow or wrap around. This method works because the number of cells is known before BFS starts.

With the mark on pop, the number of cells is not a limit for the number of pushes. The example fills a queue of 117 slots, but BFS can get to only 94 cells. The overflow is one more practical reason to mark on push.

A circular queue uses old slots again and prevents the overflow of the fixed array. But the duplicate pushes still occur.

If you do not know the maximum number of nodes before the search, you can use a structure that can grow. For example, a `std.ArrayList` with a head index can work as a queue.

[Queues](https://www.ziglang.in/learn/concurrency/queues/) explains structures for queues, and [A Growable Array](https://www.ziglang.in/learn/data-structures/growable-array/) explains dynamic storage.

## BFS work is proportional to cells and edges

With the correct mark, each cell enters the queue one time or less. Each time BFS processes a cell, it examines the possible neighbours of the cell.

On this grid, there are four possible moves:

- up
- down
- left
- right

Thus the total work is proportional to the number of cells plus the number of connections between neighbours. For a normal rectangular grid, the work is O(rows * columns).

The program shows:

```
repeated relaxation agrees on every cell -> true
  13 sweeps of the whole grid, 4940 neighbours looked at, against 376 from the queue
```

The second method of verification scans the full grid again and again. It updates the distances until no distance changes.

This method gets the same answer, but it examines 4,940 neighbour positions. BFS needs only 376 neighbour checks. The queue lets BFS process only the cells with a distance that is already known.

## BFS depends on equal edge costs

The guarantee of the shortest path above is true only if each move has the same cost. Here each move costs exactly one. Because of this, the distance levels agree with the order of the queue.

For example, a move to the right can cost 1 and a move down can cost 5. Then the first time that a cell enters the queue is not always its cheapest route. Normal BFS is not sufficient.

For weighted graphs, you need a different shortest-path algorithm. For example:

- BFS for edges that all have the same cost
- 0-1 BFS for edge costs of only 0 and 1
- Dijkstra's algorithm for non-negative edge weights
