# Breadth-First Search on a Grid

> The distance field printed as the frontier expands, and the one line whose position decides whether a cell can enter the queue twice.

Breadth-first search, or BFS, is useful for finding the shortest path on a grid when every move has the same cost.

The queue itself does not know anything about shortest paths.

What matters is the order in which BFS visits cells.

Cells one move away are processed before cells two moves away.

Cells two moves away are processed before cells three moves away.

Because of that order, the first time BFS reaches a cell, it has found the shortest route to that cell.

The example uses a grid with 9 rows and 13 columns.

It contains walls, one unreachable cell, a start position `S`, and a target `T`.

The program finds the shortest route from `S` to `T`, prints the distance field, and also demonstrates a common marking mistake.

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.grid-bfs`)*

## BFS finds the shortest route

The shortest route in this grid takes 24 moves:

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

If there were no walls, moving from the top-left area to the target would require eight downward moves and twelve rightward moves.

That is 20 moves.

The walls force the route to make four extra moves.

BFS still finds the minimum possible number of moves.

## Why DFS does not guarantee the shortest path

A depth-first search uses a stack instead of a queue.

It follows one path as far as possible before returning and trying another direction.

<SnippetSource name="23-competitive.grid-bfs" decl="dfsFirstPath" />

This DFS marks each cell when it enters it and stops when it first reaches the target.

That finds a valid route.

It does not guarantee the shortest route.

On the same grid:

```
the first route a depth-first walk finds: 68 moves, against 24
```

DFS finds a route of 68 moves while BFS finds one in 24.

The result also depends on the order of the possible moves.

Changing the order of `moves` can make DFS find a completely different route.

DFS is useful for many graph problems, but a normal DFS is not the correct tool when the problem asks for the fewest moves in an unweighted graph or grid.

## Moving safely with usize coordinates

<SnippetSource name="23-competitive.grid-bfs" decl="step" />

Rows and columns are stored as `usize` because they are used as array indices.

That creates a problem when moving up or left.

Suppose the current row is 0.

This expression is invalid:

`p.r - 1`

A `usize` cannot represent `-1`.

The subtraction underflows before we get a chance to test whether the result is inside the grid.

The same problem happens when moving left from column 0.

The code avoids this by doing the movement calculation using `isize`.

For example, moving up from `(0, 0)` produces:

`(-1, 0)`

That is a valid `isize` value.

We can then check whether both coordinates are inside the grid.

Only after the bounds check do we convert them back to `usize`.

For example:

```
  move    dr  dc     r     c  on the grid
  up      -1   0    -1     0  no
  down     1   0     1     0  yes
  left     0  -1     0    -1  no
  right    0   1     0     1  yes
```

From the top-left corner, moving up and left produces negative coordinates.

Those moves are rejected before any array access happens.

Moving down and right is valid.

Another approach is to check before subtracting.

For example:

`if (p.r > 0)`

before calculating `p.r - 1`.

Both approaches are valid.

The important rule is not to subtract 1 from a zero `usize` and then try to check the result afterwards.

## Why BFS gives the shortest distance

<SnippetSource name="23-competitive.grid-bfs" decl="bfsMarkOnPush" />

BFS processes the grid one distance level at a time.

The start cell has distance 0.

Its neighbours have distance 1.

Their unvisited neighbours have distance 2.

And so on.

The queue preserves this order.

For example:

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

The cells marked 5 are the current frontier.

Every cell with a smaller distance has already been processed.

This ordering gives us the shortest-path guarantee.

Suppose a cell is first reached from another cell at distance `d`.

We assign it:

`d + 1`

Could a shorter route appear later?

No.

Anything processed later is at distance `d` or greater.

So any later route to the same cell would also have length at least `d + 1`.

The first distance written is therefore already the shortest distance.

That means BFS does not need to keep comparing possible distances for the same cell.

It can mark the cell once and never revisit it.

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

The cell at row 2, column 10 remains a dot.

It is surrounded by walls and cannot be reached.

There are 95 open cells in the grid.

BFS reaches 94 of them.

One remains unreachable.

## Mark a cell when it enters the queue

A very common BFS bug is marking cells too late.

The correct version marks a cell as visited when it is pushed into the queue.

That prevents another neighbour from pushing the same cell again.

Now move that marking step to the point where the cell is popped.

<SnippetSource name="23-competitive.grid-bfs" decl="bfsMarkOnPop" />

The final distances are still correct.

But the search does unnecessary work.

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

When we mark on push, every reachable cell enters the queue exactly once.

There are 94 reachable cells.

So there are exactly 94 pushes and 94 pops.

When we mark on pop, a cell remains unmarked while it is waiting in the queue.

During that time, several neighbouring cells may discover it.

Each one sees it as unvisited and pushes it again.

That creates duplicates.

The second version performs 143 pushes.

Forty-nine pops are duplicates that have already been processed earlier.

The result is still correct because the code checks `seen` when the cell is popped.

But the queue does much more work.

The correct rule is:

Mark a node when you enqueue it, not when you dequeue it.

## Why marking on push matters

Consider a cell that can be reached from three neighbouring cells.

With marking on push:

1. The first neighbour discovers it.
2. The cell is marked.
3. The first neighbour pushes it.
4. The other neighbours later see that it is already marked.
5. They do not push it again.

The cell enters the queue once.

With marking on pop:

1. The first neighbour pushes it.
2. The cell is still unmarked.
3. A second neighbour pushes it.
4. A third neighbour may push it too.
5. Only later does the first copy leave the queue and become marked.

The duplicates are already inside the queue by then.

On a grid, each cell has only a small number of neighbours, so the extra work is limited by a constant factor.

On a general graph, a vertex may have many neighbours.

Then the number of unnecessary pushes can become much larger.

## Sizing the queue

<SnippetSource name="23-competitive.grid-bfs" decl="Queue" />

The queue in this example uses a plain array and two indices.

It does not reuse positions after they are popped.

That means the required storage depends on the total number of pushes, not only on how many items are waiting at one time.

With correct marking, every reachable cell is pushed exactly once.

So a grid with `rows * columns` cells needs at most that many queue slots.

For this grid:

`9 * 13 = 117`

So 117 slots are enough.

No dynamic growth is required.

No circular buffer is required.

The queue can simply allocate space for all cells once.

This works because the number of cells is known before BFS starts.

With marking on pop, the number of pushes is no longer bounded by the number of cells.

The example fills a queue of 117 slots even though only 94 cells are reachable.

That is another practical reason to mark on push.

A circular queue would reuse old slots and avoid the fixed-array overflow, but it would not solve the real problem.

The duplicate pushes would still happen.

Where the maximum number of nodes is not known in advance, a growable structure can be used.

For example, a `std.ArrayList` plus a head index can work as a queue.

[Queues](https://www.ziglang.in/learn/concurrency/queues/) covers queue-related structures, and [A Growable Array](https://www.ziglang.in/learn/data-structures/growable-array/) covers dynamic storage.

## BFS work is proportional to cells and edges

With correct marking, every cell enters the queue at most once.

Each time we process a cell, we inspect its possible neighbours.

On this grid, there are four possible moves:

- up
- down
- left
- right

So the total work is proportional to the number of cells plus the number of neighbour connections.

For a normal rectangular grid, this is O(rows * columns).

The program reports:

```
repeated relaxation agrees on every cell -> true
  13 sweeps of the whole grid, 4940 neighbours looked at, against 376 from the queue
```

The alternative verification method repeatedly scans the entire grid and updates distances until nothing changes.

It eventually gets the same answer.

But it inspects 4,940 neighbour positions.

BFS needs only 376 neighbour checks.

The queue lets BFS process only the cells whose distance has actually become known.

## BFS depends on equal edge costs

The shortest-path guarantee above depends on every move costing the same amount.

Here every move costs exactly one.

That is why distance levels line up with queue order.

If moving right cost 1 but moving down cost 5, the first time a cell enters the queue would no longer necessarily be its cheapest route.

Normal BFS would not be enough.

For weighted graphs, another shortest-path algorithm is needed.

For example:

- BFS for edges that all have the same cost
- 0-1 BFS for edge costs of only 0 and 1
- Dijkstra's algorithm for non-negative edge weights

The key idea is that ordinary BFS gives shortest paths because the queue processes nodes in increasing number of moves from the start.
