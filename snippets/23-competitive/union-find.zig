//! title: Union-Find (Disjoint Set Union)
//! Groups that merge when edges arrive, and an answer to the question "are
//! these two in the same group?" after each edge. The program runs three
//! versions and prints the cost of each version. The first version relabels a
//! whole group. The second version is a parent array with no balance. The
//! third version is the full structure with union by size and path
//! compression. CI compares each table in the
//! chapter with the output.

const std = @import("std");

/// The problem, as text.
///
/// A snippet here runs under WASI in a browser tab. The tab has no stdin to
/// read. The first line is the number of nodes. Each line after the first line
/// is one edge. The edges arrive in the order of the lines.
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

/// The maximum number of nodes and edges in the parsed problem.
///
/// A contest gives its bounds. Thus the bounds set the size of the arrays one
/// time, and the program allocates no memory.
const max_nodes = 16;
const max_edges = 32;

/// The size of the large runs at the end of the output.
const scale_n = 1000;
const scale_random_edges = 1000;

/// A recursive find must follow a chain of this length.
const long_n = 1_000_000;

var long_parent: [long_n]u32 = undefined;
var long_size: [long_n]u32 = undefined;

const Edge = struct { a: u32, b: u32 };

const Problem = struct { n: u32, edges: []const Edge };

/// Read the node count from a reader, then read one edge from each line.
///
/// The function takes a `*std.Io.Reader` instead of the string. The networking
/// chapters use the same method for protocols. If an edge names a node that
/// does not exist, this function rejects the edge. Thus the error does not
/// occur later, at the first index past the end.
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

/// The work that the simple version did.
const RelabelWork = struct {
    reads: usize = 0,
    rewrites: usize = 0,
};

/// The simple version: each node has the label of its group.
///
/// To check whether two nodes are connected costs one comparison. The merge
/// is the expensive half. The function must find each node with the label of
/// `a` and give it the label of `b`. To find these nodes, the function reads
/// the whole array.
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

/// Follow the parent links until a node is its own parent.
///
/// That node is the root, and the root is the name of the group. Two nodes
/// are connected if and only if they get to the same root.
fn findRoot(parent: []const u32, x: u32) u32 {
    var node = x;
    while (parent[node] != node) node = parent[node];
    return node;
}

/// Merge two groups. Put one root under the other root.
///
/// Only a root changes. No other node in the two groups changes. Thus this
/// merge costs less than a relabel. This function does not select the root
/// that goes under the other root. The chain below shows the problem.
fn unitePlain(parent: []u32, a: u32, b: u32) bool {
    const ra = findRoot(parent, a);
    const rb = findRoot(parent, b);
    if (ra == rb) return false;
    parent[ra] = rb;
    return true;
}

/// The version to copy into a solution.
///
/// `find` follows the links to the root. Then it follows the same path again
/// and points each node on the path directly at the root. It has two loops
/// and no recursion. Thus a chain of a million nodes costs a million steps one
/// time, and a fixed amount of stack.
///
/// `unite` puts the smaller group under the larger group. A node moves further
/// from its root only when its group becomes two or more times as large. Thus
/// no tree is taller than log2 of the node count.
///
/// `count` is the number of groups. At the start, there is one group for each
/// node. `count` decreases by one on each union that merged two different
/// groups.
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

/// The same find, as a recursive function.
///
/// This version is shorter, and it is correct. But it makes one call for each
/// link on the path. The first find on a tall chain has a very long path.
fn findRecursive(parent: []u32, x: u32) u32 {
    if (parent[x] == x) return x;
    parent[x] = findRecursive(parent, parent[x]);
    return parent[x];
}

/// A common mistake: a check for the same parent.
///
/// Two nodes with the same parent also have the same root. Thus the check
/// never joins two separate groups. But the check says "no" to
/// each pair at different depths of the same tree.
fn connectedByParent(parent: []const u32, a: u32, b: u32) bool {
    return parent[a] == parent[b];
}

/// A different common mistake: a link between the nodes instead of their roots.
///
/// The root check is correct. The link is not correct. `parent[a] = b` removes
/// `a` and all nodes below `a` from the old tree. The other nodes of the old
/// tree stay as a separate group.
fn uniteNodes(parent: []u32, a: u32, b: u32) bool {
    if (findRoot(parent, a) == findRoot(parent, b)) return false;
    parent[a] = b;
    return true;
}

/// A forest with counters, for the experiments.
///
/// The forest has two switches and a step counter. It is separate from
/// `DisjointSet`. Thus `DisjointSet` keeps the shape that you can copy into a
/// solution.
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

    /// The number of links from `x` to its root. This count does not compress
    /// a path.
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

/// The four combinations of the two switches, in the order of the table.
const variants = [4]struct { name: []const u8, by_size: bool, compress: bool }{
    .{ .name = "plain", .by_size = false, .compress = false },
    .{ .name = "by size", .by_size = true, .compress = false },
    .{ .name = "compress", .by_size = false, .compress = true },
    .{ .name = "both", .by_size = true, .compress = true },
};

/// The edges `0-1`, `0-2`, `0-3` and more. Each edge joins a new node to
/// node 0.
///
/// With no balance, the old root always goes under the new single node. Thus
/// the tree becomes one link taller for each edge, and node 0 moves to the
/// bottom.
fn fillChain(out: []Edge) []Edge {
    for (out, 1..) |*e, i| e.* = .{ .a = 0, .b = @intCast(i) };
    return out;
}

/// Edges between random pairs, from a fixed linear congruential generator.
/// Thus the printed counts are the same on all machines.
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

/// The simple version on the input, with one row for each edge.
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

/// The plain parent array on the input: the roots, the links to the roots,
/// and the group count after each edge.
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

    // Path compression on the same forest, one find at a time.
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

/// The chain with each of the four variants, with one row for each edge.
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

/// The full structure on the input.
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

    // On a forest of this small size, recursion gives the same roots.
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
    // A correct forest without compression. Thus some trees stay deep.
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

    // A link between the nodes instead of their roots.
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

/// A chain of a million nodes, and the cost to find the root from the bottom.
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
/// The simple version reads the whole label array on each merge. Thus its
/// reads are the node count multiplied by the merges. For the four forests,
/// the count is the links that `find` follows. `find` is the only loop in the
/// forests.
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

    // The two tables use the same three lists of edges. The program writes
    // the second table into a buffer and prints it after the first table.
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
