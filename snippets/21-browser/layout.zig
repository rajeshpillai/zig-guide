//! title: Layout
//! Widths flow down from the parent. Heights add up from the children.

const std = @import("std");
const dom = @import("html.zig");
const style = @import("css.zig");

pub const Box = struct {
    node: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    padding: i32 = 0,
    margin: i32 = 0,
    first: ?u32 = null,
    next: ?u32 = null,
};

/// Every line of text is this tall. A real engine measures the font, breaks
/// the text into lines that fit the width, and the height falls out of how
/// many lines there were. That is inline layout, and it is a different
/// algorithm from the block layout below.
const line_height: i32 = 20;

pub const Engine = struct {
    nodes: []const dom.Node,
    rules: []const style.Rule,
    boxes: []Box,
    used: u32 = 0,

    fn number(e: Engine, node: dom.Node, property: []const u8, default: i32) i32 {
        const text = style.cascade(e.rules, node, property) orelse return default;
        return std.fmt.parseInt(i32, text, 10) catch default;
    }

    fn add(e: *Engine, box: Box) !u32 {
        if (e.used == e.boxes.len) return error.TooManyBoxes;
        e.boxes[e.used] = box;
        e.used += 1;
        return e.used - 1;
    }

    /// Pass one, downwards. A block's width is decided by its parent, because
    /// a block fills the space it is given. Nothing about the children is
    /// consulted, which is why this pass can run before they exist.
    pub fn buildWidths(e: *Engine, node_index: u32, available: i32) !u32 {
        const node = e.nodes[node_index];
        const margin = e.number(node, "margin", 0);
        const padding = e.number(node, "padding", 0);

        const explicit = style.cascade(e.rules, node, "width");
        const width = if (explicit) |text|
            std.fmt.parseInt(i32, text, 10) catch available
        else
            available - 2 * margin - 2 * padding;

        const box = try e.add(.{
            .node = node_index,
            .width = width,
            .margin = margin,
            .padding = padding,
        });

        var last: ?u32 = null;
        var child = node.first;
        while (child) |c| : (child = e.nodes[c].next) {
            const child_box = try e.buildWidths(c, width);
            if (last) |l| e.boxes[l].next = child_box else e.boxes[box].first = child_box;
            last = child_box;
        }
        return box;
    }

    /// Pass two, upwards. A block's height is whatever its children needed,
    /// which cannot be known until they have been laid out. Positions are
    /// assigned on the way down, heights collected on the way back.
    pub fn placeAndSize(e: *Engine, box_index: u32, x: i32, y: i32) i32 {
        const box = &e.boxes[box_index];
        box.x = x + box.margin + box.padding;
        box.y = y + box.margin + box.padding;

        if (e.nodes[box.node].kind == .text) {
            box.height = line_height;
            return box.height + 2 * box.margin + 2 * box.padding;
        }

        var cursor = box.y;
        var child = box.first;
        while (child) |c| : (child = e.boxes[c].next) {
            cursor += e.placeAndSize(c, box.x, cursor);
        }

        const explicit = style.cascade(e.rules, e.nodes[box.node], "height");
        box.height = if (explicit) |text|
            std.fmt.parseInt(i32, text, 10) catch (cursor - box.y)
        else
            cursor - box.y;

        return box.height + 2 * box.margin + 2 * box.padding;
    }
};

fn show(e: Engine, index: u32, depth: usize, out: *std.Io.Writer) !void {
    const box = e.boxes[index];
    const node = e.nodes[box.node];
    for (0..depth) |_| try out.writeAll("  ");
    const label = if (node.kind == .text) "#text" else node.name;
    // Formatted into a string first, then padded. Giving an integer a width
    // makes this compiler print a sign with it (`{d:<4}` on 7 is "+7  "), and
    // a column of plus signs is not what a box tree should look like.
    var cell: [4][8]u8 = undefined;
    try out.print("{s: <8} x={s: <5} y={s: <5} w={s: <5} h={s}\n", .{
        label,
        try std.mem.print(&cell[0], "{d}", .{box.x}),
        try std.mem.print(&cell[1], "{d}", .{box.y}),
        try std.mem.print(&cell[2], "{d}", .{box.width}),
        try std.mem.print(&cell[3], "{d}", .{box.height}),
    });
    var child = box.first;
    while (child) |c| : (child = e.boxes[c].next) try show(e, c, depth + 1, out);
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const html =
        \\<div id=page>
        \\<h1>Title</h1>
        \\<div class=box><p>One</p><p>Two</p></div>
        \\<p>Footer</p>
        \\</div>
    ;
    const sheet =
        \\#page { padding: 10 }
        \\.box { margin: 5; padding: 5 }
        \\h1 { height: 40 }
    ;

    var nodes: [32]dom.Node = undefined;
    const tree = try dom.parseInto(html, &nodes);

    var rules_buf: [8]style.Rule = undefined;
    const rules = try style.parse(sheet, &rules_buf);

    var boxes: [32]Box = undefined;
    var engine: Engine = .{ .nodes = &nodes, .rules = rules, .boxes = &boxes };

    const viewport: i32 = 400;
    const root = try engine.buildWidths(tree.root, viewport);
    _ = engine.placeAndSize(root, 0, 0);

    try out.print("viewport is {d} wide\n\n", .{viewport});
    try show(engine, root, 0, out);

    try out.writeAll("\nwidths were decided before any child was measured;\n");
    try out.writeAll("heights could not be known until every child was placed.\n");

    try out.flush();
}
