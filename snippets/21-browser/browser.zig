//! title: The Whole Pipeline
//! Bytes, tree, styles, boxes, pixels. Five stages, in one direction.

const std = @import("std");
const dom = @import("html.zig");
const style = @import("css.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");

/// Everything a page needs, in the order it happens. Each stage takes only
/// what the previous one produced, which is why each has been a chapter of its
/// own and why any of them could be replaced without touching the others.
fn open(html: []const u8, sheet: []const u8, out: *std.Io.Writer) !void {
    // 1. Bytes to a tree. Cannot fail.
    var nodes: [64]dom.Node = undefined;
    const tree = try dom.parseInto(html, &nodes);

    // 2. Bytes to rules. The tree is not consulted.
    var rules_buf: [16]style.Rule = undefined;
    const rules = try style.parse(sheet, &rules_buf);

    // 3. Tree plus rules to boxes with widths, top down.
    var boxes: [64]layout.Box = undefined;
    var engine: layout.Engine = .{ .nodes = &nodes, .rules = rules, .boxes = &boxes };
    const root = try engine.buildWidths(tree.root, 400);

    // 4. Boxes get positions and heights, bottom up.
    _ = engine.placeAndSize(root, 0, 0);

    // 5. Boxes to pixels, back to front.
    var canvas: render.Canvas = .{};
    render.paint(engine, rules, root, &canvas);
    try canvas.show(out);

    try out.print("\n{d} nodes, {d} rules, {d} boxes\n", .{ tree.used, rules.len, engine.used });
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const html =
        \\<div id=page>
        \\<h1>Zig</h1>
        \\<div class=row><p>alpha</p><p>beta</p></div>
        \\<p class=note>footer</p>
        \\</div>
    ;

    const sheet =
        \\#page { padding: 10; background: . }
        \\h1 { height: 30; background: # }
        \\.row { margin: 5; padding: 5; background: o }
        \\.note { background: - }
    ;

    try out.writeAll("as written\n\n");
    try open(html, sheet, out);

    // The same document with one declaration changed. Nothing else moves,
    // which is the property that makes a stylesheet worth having.
    const restyled =
        \\#page { padding: 10; background: . }
        \\h1 { height: 60; background: # }
        \\.row { margin: 5; padding: 5; background: o }
        \\.note { background: - }
    ;

    try out.writeAll("\nwith h1 twice as tall, and nothing else touched\n\n");
    try open(html, restyled, out);

    try out.flush();
}
