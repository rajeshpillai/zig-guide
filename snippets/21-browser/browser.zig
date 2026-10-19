//! title: The Whole Pipeline
//! Bytes, tree, styles, boxes, pixels. Five stages, in one direction.

const std = @import("std");
const dom = @import("html.zig");
const style = @import("css.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");

/// All the stages that a page needs, in the order that they run. Each stage
/// uses only what the previous stage made. Thus each stage has a chapter of
/// its own, and you can replace one stage without a change to the others.
fn open(html: []const u8, sheet: []const u8, out: *std.Io.Writer) !void {
    // 1. Bytes to a tree. This stage cannot fail.
    var nodes: [64]dom.Node = undefined;
    const tree = try dom.parseInto(html, &nodes);

    // 2. Bytes to rules. This stage does not look at the tree.
    var rules_buf: [16]style.Rule = undefined;
    const rules = try style.parse(sheet, &rules_buf);

    // 3. Tree and rules to boxes with widths, from the top down.
    var boxes: [64]layout.Box = undefined;
    var engine: layout.Engine = .{ .nodes = &nodes, .rules = rules, .boxes = &boxes };
    const root = try engine.buildWidths(tree.root, 400);

    // 4. Give the boxes positions and heights, from the bottom up.
    _ = engine.placeAndSize(root, 0, 0);

    // 5. Boxes to pixels, from back to front.
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

    // The same document, with a change to one declaration and to nothing
    // else. This property makes a stylesheet useful.
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
