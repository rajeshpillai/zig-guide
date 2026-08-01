//! title: Painting
//! A rectangle of memory, filled back to front. The last write wins.

const std = @import("std");
const dom = @import("html.zig");
const style = @import("css.zig");
const layout = @import("layout.zig");

pub const cols = 50;
pub const rows = 15;

/// The framebuffer. A real one holds four bytes per pixel and is handed to the
/// compositor; this one holds a character per cell so the result can be read
/// in a terminal. Nothing else about the algorithm changes.
pub const Canvas = struct {
    cells: [rows][cols]u8 = @splat(@splat('.')),

    pub fn fill(c: *Canvas, x: i32, y: i32, w: i32, h: i32, ink: u8) void {
        var row = y;
        while (row < y + h) : (row += 1) {
            if (row < 0 or row >= rows) continue;
            var col = x;
            while (col < x + w) : (col += 1) {
                if (col < 0 or col >= cols) continue;
                c.cells[@intCast(row)][@intCast(col)] = ink;
            }
        }
    }

    pub fn show(c: Canvas, out: *std.Io.Writer) !void {
        for (c.cells) |row| try out.print("{s}\n", .{&row});
    }
};

/// Parents first, then children, in document order. That ordering is the
/// painter's algorithm: everything is drawn, and something drawn later simply
/// covers what was there. No depth test, no clipping, no cleverness.
pub fn paint(
    engine: layout.Engine,
    rules: []const style.Rule,
    box_index: u32,
    canvas: *Canvas,
) void {
    const box = engine.boxes[box_index];
    const node = engine.nodes[box.node];

    if (node.kind == .element) {
        const ink = if (style.cascade(rules, node, "background")) |text|
            text[0]
        else
            ' ';
        if (ink != ' ') {
            canvas.fill(
                @divTrunc(box.x, 8),
                @divTrunc(box.y, 10),
                @divTrunc(box.width, 8),
                @divTrunc(box.height, 10),
                ink,
            );
        }
    } else {
        // Text is painted as itself, clipped to the box it sits in.
        const text = node.text;
        const x = @divTrunc(box.x, 8);
        const y = @divTrunc(box.y, 10);
        if (y >= 0 and y < rows) {
            for (text, 0..) |ch, i| {
                const col = x + @as(i32, @intCast(i));
                if (col >= 0 and col < cols) canvas.cells[@intCast(y)][@intCast(col)] = ch;
            }
        }
    }

    var child = box.first;
    while (child) |c| : (child = engine.boxes[c].next) paint(engine, rules, c, canvas);
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const html =
        \\<div id=page><h1>Title</h1><div class=box><p>One</p><p>Two</p></div></div>
    ;
    const sheet =
        \\#page { padding: 10; background: - }
        \\.box { margin: 5; padding: 5; background: o }
        \\h1 { height: 40; background: = }
    ;

    var nodes: [32]dom.Node = undefined;
    const tree = try dom.parseInto(html, &nodes);

    var rules_buf: [8]style.Rule = undefined;
    const rules = try style.parse(sheet, &rules_buf);

    var boxes: [32]layout.Box = undefined;
    var engine: layout.Engine = .{ .nodes = &nodes, .rules = rules, .boxes = &boxes };
    const root = try engine.buildWidths(tree.root, 400);
    _ = engine.placeAndSize(root, 0, 0);

    var canvas: Canvas = .{};
    paint(engine, rules, root, &canvas);
    try canvas.show(out);

    try out.writeAll("\n#page painted first, then h1 over it, then .box,\n");
    try out.writeAll("then the text of each paragraph over that.\n");

    try out.flush();
}
