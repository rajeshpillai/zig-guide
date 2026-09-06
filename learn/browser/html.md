# An HTML Parser

> A format with no parse errors, because the browsers that shipped first decided so.

Every parser in this guide so far has been allowed to refuse. The HTTP request
parser rejects a header with no colon. The language parser reports
`UnexpectedToken`. Refusing is how a parser tells you the input was not what
it claimed to be.

HTML cannot refuse. There is no such thing as an HTML document that fails to
parse, and that is not an oversight. The specification defines the exact tree
that every possible byte sequence produces, including sequences no author
would ever write on purpose.

The reason is historical and worth knowing, because it explains most of what
makes this parser strange. By the time anybody wrote a standard, there were
millions of pages already on the web, most of them malformed, all of them
rendering fine in the browsers people used. A new browser that rejected them
would have looked broken. So the standard describes what the existing browsers
already did, error recovery included, and "be lenient" became a written rule
rather than a shortcut.

## The program

```zig
const std = @import("std");

pub const Kind = enum { element, text };

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    kind: Kind,
    /// Tag name for an element, empty for text.
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

/// Elements that can never have children. `<br>` is not an error waiting for
/// `</br>`; it is complete on its own, and a parser that pushes it onto the
/// open-element stack swallows the rest of the document.
fn isVoid(name: []const u8) bool {
    inline for (.{ "br", "img", "hr", "input", "meta", "link" }) |v| {
        if (std.ascii.eqlIgnoreCase(name, v)) return true;
    }
    return false;
}

/// An open `<p>` is closed by the next `<p>`, because a paragraph cannot
/// contain a paragraph. HTML has a table of these rules and they are the
/// reason a document with no closing tags still produces a sensible tree.
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
    /// Elements opened and not yet closed. The tree is built by appending to
    /// whatever is on top.
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
        // Walk down looking for a matching open element. If there is none, the
        // end tag is stray and is ignored rather than being an error, which is
        // what "no parse errors" means in practice.
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
                // Whitespace between tags is not content here. A real browser
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

    // Deliberately sloppy, and all of it is legal HTML.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.html`)*

## What just happened

The input contains four things that would be errors in XML. All four produced
a sensible tree.

**The first `<p>` was never closed**, and it did not swallow the second one.
They came out as siblings, because HTML says an open `<p>` is closed by a
starting `<p>`. A paragraph cannot contain a paragraph, so the parser closes
the first one for you. The real specification has a table of these rules
covering list items, table cells, and about a dozen more.

**`<img>` is complete on its own.** It is a **void element**: it can never have
children, so it is added to the tree and not pushed onto the open-element
stack. Get this wrong and everything after `<img>` becomes its child, which
means the rest of the document ends up nested inside an image.

**`</span>` closed nothing.** Nothing named `span` was open, so the end tag is
ignored. It is not an error and it is not a guess: the rule is to look for a
matching open element and do nothing if there isn't one.

**`id=main` had no quotes**, and is legal. Attribute values only need quoting
when they contain a space or a quote.

**The stack is what builds the tree.** There is no recursion here, unlike the
language parser. Elements are pushed when opened and popped when closed, and
every node is appended to whatever is on top. That is a more natural fit for a
format where the nesting can be repaired as you go.

## Check yourself

The parser trims whitespace between tags and drops it if nothing is left.
Where would that be wrong?

Inside a paragraph. `<p>Hello <b>world</b></p>` has a space before `<b>` that
is doing real work: without it the rendered text reads `Helloworld`. A real
browser keeps that whitespace, collapses runs of it into one space, and then
drops it in contexts where it cannot be seen.

The rules for which is which are genuinely fiddly. They are the reason
inline-block elements have mysterious gaps between them, and why minifiers are
careful about removing newlines in HTML but not in CSS. This parser drops it
all so the tree is readable, and doing so loses information a layout engine
would need.

## If you have written C

The tokenizer is a state machine over bytes, and the C version is the same
switch you would write for any of the parsers in the Unix tools section. The
part that gets big is not the parsing.

It is the tree. Every node needs children, and children come and go as the
parser repairs nesting. So C reaches for one allocation per node and a linked
list per child list, and then owns freeing all of it when the document is
thrown away. The version here uses indices into one flat array. The whole
document is freed by dropping the array, and a node is 64 bytes with no
allocation at all.

The other thing worth knowing is that real HTML parsers are enormous. The
specification's tokenizer has around 80 states, and the tree construction
stage has a dozen "insertion modes" with different rules each. That is not
complexity anybody wanted: it is the cost of specifying, byte by byte, what
twenty years of accumulated browser behaviour actually did.

Next: a stylesheet, which decides what these nodes should look like.
