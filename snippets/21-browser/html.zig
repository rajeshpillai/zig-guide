//! title: An HTML Parser
//! A format with no parse errors, because the browsers that shipped first decided so.

const std = @import("std");

pub const Kind = enum { element, text };

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    kind: Kind,
    /// The tag name of an element. For text, the name is empty.
    name: []const u8 = "",
    text: []const u8 = "",
    attrs: [4]Attr = undefined,
    attr_count: u8 = 0,
    first: ?u32 = null,
    next: ?u32 = null,

    pub fn attr(n: Node, name: []const u8) ?[]const u8 {
        for (n.attrs[0..n.attr_count]) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }
};

/// Elements that can never have children. `<br>` does not wait for a `</br>`.
/// The element is complete without an end tag. If a parser pushes it onto
/// the stack of open elements, the remainder of the document goes inside it.
fn isVoid(name: []const u8) bool {
    inline for (.{ "br", "img", "hr", "input", "meta", "link" }) |v| {
        if (std.ascii.eqlIgnoreCase(name, v)) return true;
    }
    return false;
}

/// The next `<p>` closes an open `<p>`, because a paragraph cannot contain a
/// paragraph. HTML has a table of these rules. Because of these rules, a
/// document with no end tags still gives a sensible tree.
fn closedBy(open: []const u8, starting: []const u8) bool {
    return std.ascii.eqlIgnoreCase(open, "p") and
        (std.ascii.eqlIgnoreCase(starting, "p") or std.ascii.eqlIgnoreCase(starting, "div"));
}

pub const Error = error{TooManyNodes};

pub const Parser = struct {
    source: []const u8,
    nodes: []Node,
    used: u32 = 0,
    pos: usize = 0,
    /// The elements that are open and not yet closed. The parser builds the
    /// tree: it appends each node to the element at the top.
    open: [16]u32 = undefined,
    depth: usize = 0,

    fn add(p: *Parser, node: Node) Error!u32 {
        if (p.used == p.nodes.len) return error.TooManyNodes;
        p.nodes[p.used] = node;
        p.used += 1;
        return p.used - 1;
    }

    fn appendChild(p: *Parser, child: u32) void {
        const parent = p.open[p.depth - 1];
        if (p.nodes[parent].first) |first| {
            var last = first;
            while (p.nodes[last].next) |n| last = n;
            p.nodes[last].next = child;
        } else {
            p.nodes[parent].first = child;
        }
    }

    fn closeUntil(p: *Parser, name: []const u8) void {
        // Walk down the stack and find an open element with the same name. If
        // there is none, the end tag is stray. The parser ignores it, and it
        // is not an error. That is what "no parse errors" means in practice.
        var i = p.depth;
        while (i > 1) : (i -= 1) {
            if (std.ascii.eqlIgnoreCase(p.nodes[p.open[i - 1]].name, name)) {
                p.depth = i - 1;
                return;
            }
        }
    }

    pub fn parse(p: *Parser) Error!u32 {
        const root = try p.add(.{ .kind = .element, .name = "document" });
        p.open[0] = root;
        p.depth = 1;

        while (p.pos < p.source.len) {
            if (p.source[p.pos] == '<') {
                const end = std.mem.findScalarPos(u8, p.source, p.pos, '>') orelse break;
                const inner = p.source[p.pos + 1 .. end];
                p.pos = end + 1;
                if (inner.len == 0) continue;

                if (inner[0] == '/') {
                    p.closeUntil(std.mem.trim(u8, inner[1..], " "));
                    continue;
                }

                var it = std.mem.tokenizeAny(u8, inner, " \t");
                const name = it.next() orelse continue;

                if (closedBy(p.nodes[p.open[p.depth - 1]].name, name)) p.depth -= 1;

                var node: Node = .{ .kind = .element, .name = name };
                while (it.next()) |pair| {
                    if (node.attr_count == node.attrs.len) break;
                    const eq = std.mem.findScalar(u8, pair, '=') orelse {
                        node.attrs[node.attr_count] = .{ .name = pair, .value = "" };
                        node.attr_count += 1;
                        continue;
                    };
                    node.attrs[node.attr_count] = .{
                        .name = pair[0..eq],
                        .value = std.mem.trim(u8, pair[eq + 1 ..], "\"'"),
                    };
                    node.attr_count += 1;
                }

                const index = try p.add(node);
                p.appendChild(index);
                if (!isVoid(name) and p.depth < p.open.len) {
                    p.open[p.depth] = index;
                    p.depth += 1;
                }
            } else {
                const end = std.mem.findScalarPos(u8, p.source, p.pos, '<') orelse p.source.len;
                const raw = p.source[p.pos..end];
                p.pos = end;
                const text = std.mem.trim(u8, raw, " \t\n\r");
                // Here, whitespace between tags is not content. A real browser
                // keeps it, because in a `<p>` it is a space between words.
                if (text.len == 0) continue;
                const index = try p.add(.{ .kind = .text, .text = text });
                p.appendChild(index);
            }
        }
        return root;
    }
};

pub fn show(nodes: []const Node, index: u32, indent: usize, out: *std.Io.Writer) !void {
    const node = nodes[index];
    for (0..indent) |_| try out.writeAll("  ");
    switch (node.kind) {
        .text => try out.print("\"{s}\"\n", .{node.text}),
        .element => {
            try out.print("<{s}", .{node.name});
            for (node.attrs[0..node.attr_count]) |a| try out.print(" {s}={s}", .{ a.name, a.value });
            try out.writeAll(">\n");
        },
    }
    var child = node.first;
    while (child) |c| : (child = nodes[c].next) try show(nodes, c, indent + 1, out);
}

pub fn parseInto(source: []const u8, nodes: []Node) Error!struct { root: u32, used: u32 } {
    var p: Parser = .{ .source = source, .nodes = nodes };
    const root = try p.parse();
    return .{ .root = root, .used = p.used };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // This source has four intentional mistakes. The HTML specification tells
    // a parser how to recover from each one, thus a browser shows the page.
    const source =
        \\<h1 class="title">Hello</h1>
        \\<p>First paragraph
        \\<p>Second, and the first was never closed
        \\<div id=main>
        \\  <img src="cat.png">
        \\  text after a void element
        \\</div>
        \\</span>
    ;

    var nodes: [64]Node = undefined;
    const tree = try parseInto(source, &nodes);

    try show(&nodes, tree.root, 0, out);
    try out.print("\n{d} nodes, and every one of the four mistakes above was recovered from\n", .{tree.used});

    try out.flush();
}
