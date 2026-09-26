# Union-Find (Disjoint Set Union)

> Groups that merge as edges arrive, from a parent array where a merge moves one root and a find walks to it.

Suppose we have ten nodes and no connections between them.

Edges arrive one at a time.

After each edge, we want to know how many separate groups there are.

We also want to spot any edge that joins two nodes already in the same group.

That edge closes a cycle.

Union-find answers both questions.

It is also called disjoint set union, or DSU.

It has two operations.

`find` names the group a node belongs to.

`unite` merges two groups into one.

The program below feeds ten edges into ten nodes and solves the problem three ways, printing what each way costs as it goes.

```zig
const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab, where there is no stdin to
/// read. The first line is the number of nodes. Every line after it is one
/// edge, and the edges arrive in the order they are written.
const input =
    \\10
    \\0 1
    \\2 3
    \\1 3
    \\4 5
    \\6 7
    \\5 7
    \\0 2
    \\8 9
    \\2 6
    \\7 1
;

/// The most nodes and edges the parsed problem may hold.
///
/// A contest states its bounds, so the arrays are sized from them once and
/// nothing is allocated.
const max_nodes = 16;
const max_edges = 32;

/// The size of the scale runs at the bottom of the output.
const scale_n = 1000;
const scale_random_edges = 1000;

/// A chain this long is what a recursive find would have to walk.
const long_n = 1_000_000;

var long_parent: [long_n]u32 = undefined;
var long_size: [long_n]u32 = undefined;

const Edge = struct { a: u32, b: u32 };

const Problem = struct { n: u32, edges: []const Edge };

/// Read the node count, then one edge per line, out of a reader.
///
/// Taking a `*std.Io.Reader` rather than the string is the same discipline
/// the networking chapters use for protocols. An edge naming a node that does
/// not exist is rejected here rather than at the first index past the end.
fn readProblem(reader: *std.Io.Reader, out: []Edge) !Problem {
    const first = (try reader.takeDelimiter('\n')) orelse return error.MissingCount;
    const n = try std.fmt.parseInt(u32, std.mem.trim(u8, first, " "), 10);
    if (n > max_nodes) return error.TooManyNodes;

    var count: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const a = try std.fmt.parseInt(u32, fields.next() orelse return error.ShortEdge, 10);
        const b = try std.fmt.parseInt(u32, fields.next() orelse return error.ShortEdge, 10);
        if (a >= n or b >= n) return error.NodeOutOfRange;
        if (count == out.len) return error.TooManyEdges;
        out[count] = .{ .a = a, .b = b };
        count += 1;
    }
    return .{ .n = n, .edges = out[0..count] };
}

/// What the naive version did.
const RelabelWork = struct {
    reads: usize = 0,
    rewrites: usize = 0,
};

/// The naive version: every node carries the label of its group.
///
/// Asking whether two nodes are connected is one comparison. Merging is the
/// expensive half. Every node holding `a`'s label has to be found and given
/// `b`'s, and finding them means reading the whole array.
fn relabel(label: []u32, a: u32, b: u32, work: *RelabelWork) bool {
    const from = label[a];
    const to = label[b];
    if (from == to) return false;
    for (label) |*l| {
        work.reads += 1;
        if (l.* == from) {
            l.* = to;
            work.rewrites += 1;
        }
    }
    return true;
}

/// Follow parent links until a node is its own parent.
///
/// That node is the root, and the root is the name of the group. Two nodes
/// are connected exactly when they reach the same root.
fn findRoot(parent: []const u32, x: u32) u32 {
    var node = x;
    while (parent[node] != node) node = parent[node];
    return node;
}

/// Merge two groups by hanging one root under the other.
///
/// Only a root changes. No other node in either group is touched, which is
/// why this is cheaper than relabelling. Nothing here decides which root goes
/// underneath, and that is the problem the chain below shows.
fn unitePlain(parent: []u32, a: u32, b: u32) bool {
    const ra = findRoot(parent, a);
    const rb = findRoot(parent, b);
    if (ra == rb) return false;
    parent[ra] = rb;
    return true;
}

/// The version to paste into a solution.
///
/// `find` walks to the root, then walks the same path again and points every
/// node on it straight at the root. Two loops and no recursion, so a chain of
/// a million nodes costs a million steps once and a fixed amount of stack.
///
/// `unite` hangs the smaller group under the larger one. A node only moves
/// further from its root when its group at least doubles in size, so no tree
/// is ever taller than log2 of the node count.
///
/// `count` is the number of groups. It starts at one per node and drops by
/// one on every union that merged two different groups.
const DisjointSet = struct {
    parent: []u32,
    size: []u32,
    count: usize,

    fn init(parent: []u32, size: []u32) DisjointSet {
        for (parent, size, 0..) |*p, *s, i| {
            p.* = @intCast(i);
            s.* = 1;
        }
        return .{ .parent = parent, .size = size, .count = parent.len };
    }

    fn find(d: *DisjointSet, x: u32) u32 {
        var root = x;
        while (d.parent[root] != root) root = d.parent[root];

        var node = x;
        while (node != root) {
            const next = d.parent[node];
            d.parent[node] = root;
            node = next;
        }
        return root;
    }

    fn unite(d: *DisjointSet, a: u32, b: u32) bool {
        var ra = d.find(a);
        var rb = d.find(b);
        if (ra == rb) return false;
        if (d.size[ra] > d.size[rb]) std.mem.swap(u32, &ra, &rb);
        d.parent[ra] = rb;
        d.size[rb] += d.size[ra];
        d.count -= 1;
        return true;
    }
};

/// The same find, written recursively.
///
/// Shorter, and correct. It also makes one call per link on the path, and the
/// first find on a tall chain has a very long path.
fn findRecursive(parent: []u32, x: u32) u32 {
    if (parent[x] == x) return x;
    parent[x] = findRecursive(parent, parent[x]);
    return parent[x];
}

/// A common mistake: asking whether two nodes share a parent.
///
/// Sharing a parent does mean sharing a root, so it never says two separate
/// groups are joined. It says "no" to any pair sitting at different depths of
/// the same tree.
fn connectedByParent(parent: []const u32, a: u32, b: u32) bool {
    return parent[a] == parent[b];
}

/// Another common mistake: linking the nodes instead of their roots.
///
/// The root check is right. The link is not. `parent[a] = b` pulls `a` and
/// everything below it out of its old tree, and leaves the rest of that tree
/// behind as a separate group.
fn uniteNodes(parent: []u32, a: u32, b: u32) bool {
    if (findRoot(parent, a) == findRoot(parent, b)) return false;
    parent[a] = b;
    return true;
}

/// An instrumented forest for the experiments.
///
/// Two switches and a step counter. Kept separate from `DisjointSet` so that
/// one stays the shape you would paste into a solution.
const Forest = struct {
    parent: []u32,
    size: []u32,
    by_size: bool,
    compress: bool,
    steps: usize = 0,

    fn init(parent: []u32, size: []u32, by_size: bool, compress: bool) Forest {
        for (parent, size, 0..) |*p, *s, i| {
            p.* = @intCast(i);
            s.* = 1;
        }
        return .{ .parent = parent, .size = size, .by_size = by_size, .compress = compress };
    }

    fn find(f: *Forest, x: u32) u32 {
        var root = x;
        while (f.parent[root] != root) {
            root = f.parent[root];
            f.steps += 1;
        }
        if (f.compress) {
            var node = x;
            while (node != root) {
                const next = f.parent[node];
                f.parent[node] = root;
                node = next;
            }
        }
        return root;
    }

    fn unite(f: *Forest, a: u32, b: u32) bool {
        var ra = f.find(a);
        var rb = f.find(b);
        if (ra == rb) return false;
        if (f.by_size and f.size[ra] > f.size[rb]) std.mem.swap(u32, &ra, &rb);
        f.parent[ra] = rb;
        f.size[rb] += f.size[ra];
        return true;
    }

    /// Links from `x` to its root, counted without compressing anything.
    fn depth(f: Forest, x: u32) usize {
        var node = x;
        var links: usize = 0;
        while (f.parent[node] != node) {
            node = f.parent[node];
            links += 1;
        }
        return links;
    }

    fn tallest(f: Forest) usize {
        var best: usize = 0;
        for (0..f.parent.len) |i| best = @max(best, f.depth(@intCast(i)));
        return best;
    }
};

/// The four combinations of the two switches, in the order the table prints.
const variants = [4]struct { name: []const u8, by_size: bool, compress: bool }{
    .{ .name = "plain", .by_size = false, .compress = false },
    .{ .name = "by size", .by_size = true, .compress = false },
    .{ .name = "compress", .by_size = false, .compress = true },
    .{ .name = "both", .by_size = true, .compress = true },
};

/// Edges `0-1`, `0-2`, `0-3` and on, every one joining a new node to node 0.
///
/// With no balancing, the old root goes under the new single node every time,
/// so the tree grows one link taller per edge and node 0 sinks to the bottom.
fn fillChain(out: []Edge) []Edge {
    for (out, 1..) |*e, i| e.* = .{ .a = 0, .b = @intCast(i) };
    return out;
}

/// Edges between random pairs, from a fixed linear congruential generator so
/// the printed counts are the same on every machine.
fn fillRandom(out: []Edge, n: u32) []Edge {
    var state: u32 = 20260925;
    for (out) |*e| {
        state = state *% 1664525 +% 1013904223;
        const a = (state >> 16) % n;
        state = state *% 1664525 +% 1013904223;
        const b = (state >> 16) % n;
        e.* = .{ .a = a, .b = b };
    }
    return out;
}

/// Count the distinct roots, which is the true number of groups.
fn countRoots(parent: []const u32) usize {
    var roots: usize = 0;
    for (parent, 0..) |p, i| {
        if (p == i) roots += 1;
    }
    return roots;
}

fn writeRow(out: *std.Io.Writer, values: []const u32) !void {
    for (values) |v| try out.print("{d:>3}", .{v});
}

fn writeEdge(out: *std.Io.Writer, e: Edge) !void {
    var digits: [24]u8 = undefined;
    const text = try std.mem.print(&digits, "{d}-{d}", .{ e.a, e.b });
    try out.splatByteAll(' ', 7 - text.len);
    try out.writeAll(text);
}

/// The naive version on the input, one row per edge.
fn traceRelabel(out: *std.Io.Writer, p: Problem) !void {
    var storage: [max_nodes]u32 = undefined;
    const label = storage[0..p.n];
    for (label, 0..) |*l, i| l.* = @intCast(i);

    var work: RelabelWork = .{};
    var merges: usize = 0;
    try out.writeAll("   edge  labels after                    rewritten  read\n");
    for (p.edges) |e| {
        const before = work;
        const merged = relabel(label, e.a, e.b, &work);
        if (merged) merges += 1;
        try writeEdge(out, e);
        try out.writeAll("  ");
        try writeRow(out, label);
        try out.print("{d:>11}{d:>6}", .{ work.rewrites - before.rewrites, work.reads - before.reads });
        if (!merged) try out.writeAll("  same label");
        try out.writeByte('\n');
    }
    try out.print(
        "  {d} merges, {d} labels rewritten, {d} labels read\n",
        .{ merges, work.rewrites, work.reads },
    );
}

/// The plain parent array on the input: roots, the links walked to reach
/// them, and the group count after every edge.
fn tracePlain(out: *std.Io.Writer, p: Problem) !void {
    var parent_storage: [max_nodes]u32 = undefined;
    var size_storage: [max_nodes]u32 = undefined;
    var f: Forest = .init(parent_storage[0..p.n], size_storage[0..p.n], false, false);
    var groups: usize = p.n;

    try out.writeAll("   edge  root a  links  root b  links  result             groups\n");
    for (p.edges) |e| {
        const s0 = f.steps;
        const ra = f.find(e.a);
        const s1 = f.steps;
        const rb = f.find(e.b);
        const s2 = f.steps;
        try writeEdge(out, e);
        try out.print("{d:>8}{d:>7}{d:>8}{d:>7}  ", .{ ra, s1 - s0, rb, s2 - s1 });
        if (ra == rb) {
            try out.writeAll("same root          ");
        } else {
            f.parent[ra] = rb;
            groups -= 1;
            var text: [24]u8 = undefined;
            const said = try std.mem.print(&text, "{d} now points at {d}", .{ ra, rb });
            try out.writeAll(said);
            try out.splatByteAll(' ', 19 - said.len);
        }
        try out.print("{d:>6}\n", .{groups});
    }

    try out.writeAll("\n  node  ");
    for (0..p.n) |i| try out.print("{d:>3}", .{i});
    try out.writeAll("\n  parent");
    try writeRow(out, f.parent);
    try out.writeAll("\n  depth ");
    for (0..p.n) |i| try out.print("{d:>3}", .{f.depth(@intCast(i))});
    try out.writeByte('\n');

    // Path compression on this same forest, one find at a time.
    try out.writeAll("\none compressing find on node 0 of that forest\n");
    try out.writeAll("  path before  0");
    var node: u32 = 0;
    while (f.parent[node] != node) {
        node = f.parent[node];
        try out.print(" -> {d}", .{node});
    }
    f.compress = true;
    _ = f.find(0);
    try out.writeAll("\n  path after   0");
    node = 0;
    while (f.parent[node] != node) {
        node = f.parent[node];
        try out.print(" -> {d}", .{node});
    }
    try out.writeAll("\n  parent     ");
    try writeRow(out, f.parent);
    try out.writeAll("\n  depth      ");
    for (0..p.n) |i| try out.print("{d:>3}", .{f.depth(@intCast(i))});
    try out.writeByte('\n');
}

/// The chain, run under all four variants, one row per edge.
fn traceChain(out: *std.Io.Writer, n: u32) !void {
    var edge_storage: [max_nodes]Edge = undefined;
    const edges = fillChain(edge_storage[0 .. n - 1]);

    var parents: [4][max_nodes]u32 = undefined;
    var sizes: [4][max_nodes]u32 = undefined;
    var forests: [4]Forest = undefined;
    for (&forests, variants, 0..) |*f, v, i| {
        f.* = .init(parents[i][0..n], sizes[i][0..n], v.by_size, v.compress);
    }

    try out.writeAll("   edge     plain   by size  compress      both\n");
    for (edges) |e| {
        try writeEdge(out, e);
        for (&forests) |*f| {
            const before = f.steps;
            _ = f.unite(e.a, e.b);
            try out.print("{d:>10}", .{f.steps - before});
        }
        try out.writeByte('\n');
    }
    try out.writeAll("  total");
    for (forests) |f| try out.print("{d:>10}", .{f.steps});
    try out.writeAll("\n  tallest");
    for (forests, 0..) |f, i| {
        if (i == 0) try out.print("{d:>8}", .{f.tallest()}) else try out.print("{d:>10}", .{f.tallest()});
    }
    try out.writeByte('\n');
}

/// The finished structure on the input.
fn traceDisjointSet(out: *std.Io.Writer, p: Problem, closing: []Edge) !usize {
    var parent_storage: [max_nodes]u32 = undefined;
    var size_storage: [max_nodes]u32 = undefined;
    var d: DisjointSet = .init(parent_storage[0..p.n], size_storage[0..p.n]);
    var closed: usize = 0;

    try out.writeAll("   edge  root a  size  root b  size  result                groups\n");
    for (p.edges) |e| {
        const ra = d.find(e.a);
        const rb = d.find(e.b);
        try writeEdge(out, e);
        try out.print("{d:>8}{d:>6}{d:>8}{d:>6}  ", .{ ra, d.size[ra], rb, d.size[rb] });
        if (!d.unite(e.a, e.b)) {
            closing[closed] = e;
            closed += 1;
            try out.writeAll("closes a cycle        ");
        } else {
            const top = d.find(e.a);
            const under = if (top == ra) rb else ra;
            var text: [32]u8 = undefined;
            const said = try std.mem.print(&text, "{d} under {d}, size {d}", .{ under, top, d.size[top] });
            try out.writeAll(said);
            try out.splatByteAll(' ', 22 - said.len);
        }
        try out.print("{d:>6}\n", .{d.count});
    }

    try out.writeAll("\n  node  ");
    for (0..p.n) |i| try out.print("{d:>3}", .{i});
    try out.writeAll("\n  parent");
    try writeRow(out, d.parent);
    try out.writeAll("\n  root  ");
    for (0..p.n) |i| try out.print("{d:>3}", .{d.find(@intCast(i))});
    try out.writeByte('\n');

    // Recursion gives the same roots on a forest this small.
    var copy: [max_nodes]u32 = undefined;
    @memcpy(copy[0..p.n], d.parent);
    var agree = true;
    for (0..p.n) |i| {
        if (findRecursive(copy[0..p.n], @intCast(i)) != d.find(@intCast(i))) agree = false;
    }
    try out.print("  recursive find agrees on every node -> {}\n", .{agree});
    try out.print("  {d} groups at the end\n", .{d.count});
    return closed;
}

/// The two mistakes, run on the same input.
fn traceMistakes(out: *std.Io.Writer, p: Problem) !void {
    // A correct forest built without compression, so some trees stay deep.
    var parent_storage: [max_nodes]u32 = undefined;
    const parent = parent_storage[0..p.n];
    for (parent, 0..) |*x, i| x.* = @intCast(i);
    for (p.edges) |e| _ = unitePlain(parent, e.a, e.b);

    try out.writeAll("comparing parents instead of roots, on the plain forest\n");
    try out.writeAll("   pair  parents  roots  by parent  truth\n");
    const pairs = [_]Edge{
        .{ .a = 1, .b = 2 },
        .{ .a = 0, .b = 2 },
        .{ .a = 0, .b = 7 },
        .{ .a = 4, .b = 6 },
        .{ .a = 8, .b = 9 },
        .{ .a = 0, .b = 8 },
    };
    for (pairs) |pair| {
        const said = connectedByParent(parent, pair.a, pair.b);
        const truth = findRoot(parent, pair.a) == findRoot(parent, pair.b);
        try writeEdge(out, pair);
        try out.print("{d:>6}{d:>3}{d:>4}{d:>3}", .{
            parent[pair.a],
            parent[pair.b],
            findRoot(parent, pair.a),
            findRoot(parent, pair.b),
        });
        try out.writeAll(if (said) "        yes" else "         no");
        try out.writeAll(if (truth) "    yes" else "     no");
        if (said != truth) try out.writeAll("  wrong");
        try out.writeByte('\n');
    }
    var wrong: usize = 0;
    var total: usize = 0;
    var a: u32 = 0;
    while (a < p.n) : (a += 1) {
        var b = a + 1;
        while (b < p.n) : (b += 1) {
            total += 1;
            const truth = findRoot(parent, a) == findRoot(parent, b);
            if (connectedByParent(parent, a, b) != truth) wrong += 1;
        }
    }
    try out.print("  wrong on {d} of {d} pairs, and every wrong answer is a no\n\n", .{ wrong, total });

    // Linking the nodes rather than their roots.
    var bad_storage: [max_nodes]u32 = undefined;
    const bad = bad_storage[0..p.n];
    for (bad, 0..) |*x, i| x.* = @intCast(i);
    var groups: usize = p.n;
    try out.writeAll("linking the nodes instead of their roots\n");
    try out.writeAll("   edge  parent of a  becomes  groups counted  groups that exist\n");
    for (p.edges) |e| {
        const old = bad[e.a];
        if (uniteNodes(bad, e.a, e.b)) groups -= 1;
        try writeEdge(out, e);
        if (bad[e.a] != old) {
            try out.print("{d:>13}{d:>9}", .{ old, bad[e.a] });
        } else {
            try out.writeAll("            .        .");
        }
        try out.print("{d:>16}{d:>19}\n", .{ groups, countRoots(bad) });
    }
}

/// A chain of a million nodes, and what finding its bottom costs.
fn traceLongChain(out: *std.Io.Writer) !void {
    var f: Forest = .init(&long_parent, &long_size, false, false);
    var i: u32 = 0;
    while (i + 1 < long_n) : (i += 1) _ = f.unite(i, i + 1);

    try out.print("a chain of {d} nodes, built by plain union of i and i+1\n", .{long_n});
    try out.print("  node 0 sits {d} links below its root\n", .{f.depth(0)});
    try out.print("  building it walked {d} links in total\n", .{f.steps});

    f.compress = true;
    f.steps = 0;
    const root = f.find(0);
    const first = f.steps;
    f.steps = 0;
    _ = f.find(0);
    try out.print(
        "  iterative find(0) -> {d}: {d} links the first time, {d} the second\n",
        .{ root, first, f.steps },
    );
}

/// One row of each cost table, for one list of edges.
///
/// The naive version reads the whole label array on every merge, so its reads
/// are the node count times the merges. The four forests are counted in links
/// walked by `find`, which is the only loop they have.
fn writeCostRows(
    cost: *std.Io.Writer,
    height: *std.Io.Writer,
    name: []const u8,
    n: u32,
    edges: []const Edge,
) !void {
    var label: [scale_n]u32 = undefined;
    for (label[0..n], 0..) |*l, i| l.* = @intCast(i);
    var work: RelabelWork = .{};
    for (edges) |e| _ = relabel(label[0..n], e.a, e.b, &work);

    try cost.print("  {s: <10}{d:>5}{d:>6}{d:>8}{d:>9}", .{ name, n, edges.len, work.reads, work.rewrites });
    try height.print("  {s: <10}", .{name});
    var parent: [scale_n]u32 = undefined;
    var size: [scale_n]u32 = undefined;
    for (variants) |v| {
        var f: Forest = .init(parent[0..n], size[0..n], v.by_size, v.compress);
        for (edges) |e| _ = f.unite(e.a, e.b);
        try cost.print("{d:>9}", .{f.steps});
        try height.print("{d:>9}", .{f.tallest()});
    }
    try cost.writeByte('\n');
    try height.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var reader: std.Io.Reader = .fixed(input);
    var edge_storage: [max_edges]Edge = undefined;
    const p = try readProblem(&reader, &edge_storage);

    try out.print("{d} nodes and {d} edges parsed from the input\n  ", .{ p.n, p.edges.len });
    for (p.edges) |e| try out.print(" {d}-{d}", .{ e.a, e.b });
    try out.writeAll("\n\n");

    try out.writeAll("every node carries its group's label, and a merge rewrites one group\n");
    try traceRelabel(out, p);
    try out.writeByte('\n');

    try out.writeAll("a parent array, where a merge moves one root and nothing else\n");
    try tracePlain(out, p);
    try out.writeByte('\n');

    try out.writeAll("edges 0-1, 0-2, 0-3 and on: links walked by each union\n");
    try traceChain(out, 10);
    try out.writeByte('\n');

    try out.writeAll("union by size and path compression together, on the input\n");
    var closing: [max_edges]Edge = undefined;
    const closed = try traceDisjointSet(out, p, &closing);
    try out.writeAll("  edges that closed a cycle:");
    for (closing[0..closed]) |e| try out.print(" {d}-{d}", .{ e.a, e.b });
    try out.writeAll("\n\n");

    try traceMistakes(out, p);
    try out.writeByte('\n');

    try traceLongChain(out);
    try out.writeByte('\n');

    // The same three edge lists feed both tables. The second table is
    // written into a buffer and printed after the first.
    var chain_storage: [scale_n - 1]Edge = undefined;
    var random_storage: [scale_random_edges]Edge = undefined;
    const chain = fillChain(&chain_storage);
    const random = fillRandom(&random_storage, scale_n);

    var height_buf: [512]u8 = undefined;
    var height: std.Io.Writer = .fixed(&height_buf);
    try out.writeAll("what each version costs\n");
    try out.writeAll("                          relabel      links walked by find\n");
    try out.writeAll("  input         n edges    read  rewrite    plain  by size compress     both\n");
    try writeCostRows(out, &height, "the input", p.n, p.edges);
    try writeCostRows(out, &height, "chain", scale_n, chain);
    try writeCostRows(out, &height, "random", scale_n, random);

    try out.writeAll("\nthe tallest tree each version leaves behind\n");
    try out.writeAll("  input         plain  by size compress     both\n");
    try out.writeAll(height.buffered());

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`23-competitive.union-find`)*

## The input

```
10 nodes and 10 edges parsed from the input
   0-1 2-3 1-3 4-5 6-7 5-7 0-2 8-9 2-6 7-1
```

The first line of the input holds the node count.

Every line after it is one edge.

If every edge is known before the first question, a [breadth-first search](https://www.ziglang.in/learn/competitive-programming/grid-bfs/) can count the groups too.

Union-find is for the case where edges keep arriving and the questions come in between them.

## Relabelling a whole group

The first idea is to give every node a label.

Two nodes are in the same group when they carry the same label.

Checking that costs one comparison.

Merging is where the cost goes.

<SnippetSource name="23-competitive.union-find" decl="relabel" />

To merge, every node carrying `a`'s label must switch to `b`'s label.

We can only find those nodes by reading the whole array.

```
   edge  labels after                    rewritten  read
    0-1    1  1  2  3  4  5  6  7  8  9          1    10
    2-3    1  1  3  3  4  5  6  7  8  9          1    10
    1-3    3  3  3  3  4  5  6  7  8  9          2    10
    4-5    3  3  3  3  5  5  6  7  8  9          1    10
    6-7    3  3  3  3  5  5  7  7  8  9          1    10
    5-7    3  3  3  3  7  7  7  7  8  9          2    10
    0-2    3  3  3  3  7  7  7  7  8  9          0     0  same label
    8-9    3  3  3  3  7  7  7  7  9  9          1    10
    2-6    7  7  7  7  7  7  7  7  9  9          4    10
    7-1    7  7  7  7  7  7  7  7  9  9          0     0  same label
  8 merges, 13 labels rewritten, 80 labels read
```

The edge `2-6` rewrites four labels, because node 2's group has four members by then.

The rows marked `same label` are the two edges that close a cycle.

Ten reads per merge looks harmless.

It is `n` reads per merge, though, and a graph can have `n - 1` merges.

On a chain of 1,000 nodes, the same function reads 999,000 labels.

A better version keeps a member list per group and relabels the smaller one.

That brings the total down to `O(n log n)`, but it needs a list per group.

## A parent array

Union-find stops trying to keep every node up to date.

Each node stores one other node from its group, called its parent.

A node that is its own parent is the root.

The root is the name of the group.

<SnippetSource name="23-competitive.union-find" decl="findRoot" />

To find a node's group, we follow parent links until we reach the root.

Two nodes are connected exactly when they reach the same root.

<SnippetSource name="23-competitive.union-find" decl="unitePlain" />

A merge finds both roots and points one at the other.

Only one entry in the array changes.

```
   edge  root a  links  root b  links  result             groups
    0-1       0      0       1      0  0 now points at 1       9
    2-3       2      0       3      0  2 now points at 3       8
    1-3       1      0       3      0  1 now points at 3       7
    4-5       4      0       5      0  4 now points at 5       6
    6-7       6      0       7      0  6 now points at 7       5
    5-7       5      0       7      0  5 now points at 7       4
    0-2       3      2       3      1  same root               4
    8-9       8      0       9      0  8 now points at 9       3
    2-6       3      1       7      1  3 now points at 7       2
    7-1       7      0       7      2  same root               2
```

Look at the edge `2-6`.

Node 2 is not a root, so `find` walks one link from 2 to 3.

Node 6 walks one link to 7.

Then 3 is pointed at 7, and nodes 0, 1 and 2 come along without being touched.

The `links` columns count how far each `find` walked.

The cost of this version is in those columns.

```
  node    0  1  2  3  4  5  6  7  8  9
  parent  1  3  3  7  5  7  7  7  9  9
  depth   3  2  2  1  2  1  1  0  1  0
```

Node 0 sits three links below its root.

Every `find` on node 0 pays those three links again.

## A tree can grow into a chain

`unitePlain` always hangs `a`'s root under `b`'s root.

Nothing stops it from hanging a big tree under a single node.

The chain input joins node 0 to node 1, then node 0 to node 2, and so on.

Every edge puts the old tree under a brand-new node.

```
edges 0-1, 0-2, 0-3 and on: links walked by each union
   edge     plain   by size  compress      both
    0-1         0         0         0         0
    0-2         1         1         1         1
    0-3         2         1         2         1
    0-4         3         1         2         1
    0-5         4         1         2         1
    0-6         5         1         2         1
    0-7         6         1         2         1
    0-8         7         1         2         1
    0-9         8         1         2         1
  total        36         8        15         8
  tallest       9         1         8         1
```

In the `plain` column, each union walks one link further than the last.

After nine edges, the tree is a single line nine links tall.

On `n` nodes, that adds up to about `n * n / 2` steps.

The other three columns are the two fixes, alone and together.

## Union by size

The first fix decides which root goes underneath.

We keep the size of every group at its root.

The smaller group goes under the larger one.

On a tie, either choice works.

In the chain, the tree rooted at node 1 grows by one node per edge.

Each new node is a group of size 1, so it always goes under that tree.

The tree never gets taller than one link.

The same rule holds a limit on every input.

A node gets one link further from its root only when its group joins a group at least as large.

So each extra link at least doubles the size of the node's group.

Starting from a group of one, a node's group can double at most `log2(n)` times before it holds all `n` nodes.

No tree gets taller than `log2(n)` links.

Some solutions keep a rank instead of a size.

A rank is an upper bound on the tree's height, and it gives the same limit.

## Path compression

The second fix changes `find`.

Once `find` knows the root, it walks the same path a second time.

It points every node on the path straight at the root.

The program runs one such `find` on node 0 of the plain forest above.

```
one compressing find on node 0 of that forest
  path before  0 -> 1 -> 3 -> 7
  path after   0 -> 7
  parent       7  7  3  7  5  7  7  7  9  9
  depth        1  1  2  1  2  1  1  0  1  0
```

Nodes 0 and 1 now point at 7.

Node 2 still sits two links down.

It was not on the path, so this `find` never saw it.

The `compress` column in the chain table shows the same limit.

Each union walks at most two links.

The final tree is still eight links tall.

Compression flattens the paths we walk, but it does nothing to stop the next union from hanging a tall tree under a single node.

## Both together

<SnippetSource name="23-competitive.union-find" decl="DisjointSet" />

This is the version to paste into a solution.

It uses two plain arrays sized from the problem's bounds.

`find` uses two loops and no recursion.

`unite` returns whether it merged anything.

A `false` means the two nodes were already connected, so the edge closes a cycle.

`count` goes down by one on every real merge.

```
   edge  root a  size  root b  size  result                groups
    0-1       0     1       1     1  0 under 1, size 2          9
    2-3       2     1       3     1  2 under 3, size 2          8
    1-3       1     2       3     2  1 under 3, size 4          7
    4-5       4     1       5     1  4 under 5, size 2          6
    6-7       6     1       7     1  6 under 7, size 2          5
    5-7       5     2       7     2  5 under 7, size 4          4
    0-2       3     4       3     4  closes a cycle             4
    8-9       8     1       9     1  8 under 9, size 2          3
    2-6       3     4       7     4  3 under 7, size 8          2
    7-1       7     8       7     8  closes a cycle             2
```

Our input merges groups of equal size at every step.

So union by size makes the same choices here as the plain version.

The difference is the guarantee.

On any input, a tree stays within `log2(n)` links.

```
  node    0  1  2  3  4  5  6  7  8  9
  parent  3  7  7  7  5  7  7  7  9  9
  root    7  7  7  7  7  7  7  7  9  9
  recursive find agrees on every node -> true
  2 groups at the end
  edges that closed a cycle: 0-2 7-1
```

The `parent` row is not the answer.

Node 0 still points at 3, and node 4 still points at 5.

The `root` row is the answer, and both of those reach 7.

Two groups remain: nodes 0 to 7, and nodes 8 and 9.

The same loop is the core of Kruskal's minimum spanning tree.

Sort the edges by weight with [`std.mem.sort`](https://www.ziglang.in/learn/standard-library/sorting/).

Then keep every edge that `unite` accepts.

## What it costs

The program runs every version on three edge lists.

`the input` is the ten edges above.

`chain` is the `0-1`, `0-2`, `0-3` pattern on 1,000 nodes.

`random` is 1,000 edges between random pairs of 1,000 nodes.

```
what each version costs
                          relabel      links walked by find
  input         n edges    read  rewrite    plain  by size compress     both
  the input    10    10      80       13        7        7        7        7
  chain      1000   999  999000   499500   498501      998     1995      998
  random     1000  1000  836000    49763    19800     1629     2496     1334

the tallest tree each version leaves behind
  input         plain  by size compress     both
  the input         3        3        2        2
  chain           999        1      998        1
  random           97        5        6        4
```

On the chain, the plain version walks 498,501 links.

Either fix brings that under 2,000.

Union by size alone guarantees `O(log n)` per operation.

Path compression alone gives `O(log n)` amortised per operation.

With both, the amortised cost per operation is `O(α(n))`.

`α` is the inverse Ackermann function.

It grows so slowly that it is at most 4 for any `n` a program could store.

In practice, each operation costs a few steps.

The bound is not a true constant, and its proof is long, so we will only use the result.

## Mistake: comparing parents instead of roots

Two nodes are connected when they share a root.

Sharing a parent is not the same test.

<SnippetSource name="23-competitive.union-find" decl="connectedByParent" />

The program runs it on the plain forest from earlier.

```
comparing parents instead of roots, on the plain forest
   pair  parents  roots  by parent  truth
    1-2     3  3   7  7        yes    yes
    0-2     1  3   7  7         no    yes  wrong
    0-7     1  7   7  7         no    yes  wrong
    4-6     5  7   7  7         no    yes  wrong
    8-9     9  9   9  9        yes    yes
    0-8     1  9   7  9         no     no
  wrong on 21 of 45 pairs, and every wrong answer is a no
```

Two nodes with the same parent do share a root.

So this check never joins two separate groups.

It says no whenever two nodes in the same tree sit at different depths.

On small tests the trees stay shallow, so most connected pairs really do share a parent and the check can pass for a long time.

Path compression makes the bug harder to see, because it keeps flattening the trees.

## Mistake: linking the nodes instead of their roots

<SnippetSource name="23-competitive.union-find" decl="uniteNodes" />

The root check is correct.

The link is not.

`parent[a] = b` moves `a` and everything below it into `b`'s tree.

The rest of `a`'s old tree stays behind as a separate group.

```
linking the nodes instead of their roots
   edge  parent of a  becomes  groups counted  groups that exist
    0-1            0        1               9                  9
    2-3            2        3               8                  8
    1-3            1        3               7                  7
    4-5            4        5               6                  6
    6-7            6        7               5                  5
    5-7            5        7               4                  4
    0-2            .        .               4                  4
    8-9            8        9               3                  3
    2-6            3        6               2                  3
    7-1            7        1               1                  2
```

Up to `2-6`, every merge starts from an `a` that is a root, so the bug does nothing.

At `2-6`, node 2 has parent 3.

The link moves node 2 away from 3.

Nodes 0, 1 and 3 are left as a group of their own.

The counter says 2 groups, but 3 groups exist.

Then `7-1` should close a cycle.

Instead, the two roots differ, so it counts as a merge.

The counter ends at 1, and the true answer is 2.

## Mistake: a recursive find on a long chain

<SnippetSource name="23-competitive.union-find" decl="findRecursive" />

This version compresses the path too, and it is shorter.

It gives the same roots as the iterative `find` on our input.

It also makes one call per link on the path.

The program builds a chain of a million nodes with plain union.

```
a chain of 1000000 nodes, built by plain union of i and i+1
  node 0 sits 999999 links below its root
  building it walked 0 links in total
  iterative find(0) -> 999999: 999999 links the first time, 1 the second
```

Each edge here joins a root to a single node, so building the chain walks no links.

The cost arrives on the first `find` from the bottom.

A recursive `find` on node 0 would be 999,999 calls deep before it returned once.

Every call needs a stack frame.

A million frames is more stack than a judge is likely to give you.

The iterative `find` uses a fixed amount of stack, whatever the path length.

Its first call walks every link once.

The second call walks one.

Union by size also prevents this chain, since it keeps every tree within 20 links for a million nodes.

Many solutions skip it, though, and rely on path compression alone.

With compression alone, write `find` with loops.

Node ids in a contest are usually integers from 0 to `n - 1`, which index the arrays directly.

If the nodes are names, give each one an index with a [hash map](https://www.ziglang.in/learn/data-structures/hash-map/) first.

If the node count is not known up front, the two arrays can be an [`ArrayList`](https://www.ziglang.in/learn/standard-library/arraylist/) each.
