# Painting

> A rectangle of memory, filled back to front. The last write wins.

Layout produced rectangles with positions. Painting fills them in, and it is
the least clever stage in the pipeline, which is the point worth making about
it.

There is a rectangle of memory. Every box writes its colour into the cells it
covers. Boxes are visited parents first, then children in document order, so
whatever is painted later simply covers what was there. No depth buffer, no
visibility test, no clipping against what is already drawn.

That is the **painter's algorithm**, named for exactly what it sounds like. It
is the correct choice here because the ordering is already known: the document
says what is in front of what.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.render`)*

## What just happened

**Four fills, in order, and you can read the order off the picture.** `#page`
covered its area with `-`, `h1` covered part of that with `=`, `.box` covered
a lower part with `o`, and the text was written over the top. Each stage
overwrote the last, and nothing checked whether it was about to.

**The canvas is an array.** A real framebuffer is four bytes per pixel instead
of one character, and the fill loop writes RGBA rather than a letter. Nothing
else about the structure differs, which is what the [pixel
buffers](https://www.ziglang.in/learn/graphics/pixel-buffers/) chapter builds properly.

**Clipping is a bounds check.** Every write tests whether the cell is inside
the canvas, which is what stops a box positioned off the edge from writing
outside the buffer. In a language without that check it is a buffer overflow
driven by a stylesheet.

**Text is painted, not laid out.** It goes at the box's corner and runs to the
right. Real text painting means rasterising glyphs from a font at a size, with
hinting and subpixel positioning, which the [font](https://www.ziglang.in/learn/graphics/) work in
the graphics section is closer to.

## Why this order and not another

The obvious alternative is to paint children first and let parents fill in
around them, and it fails immediately. A parent's background would need to
know the shape of the union of its children, which is a much harder question
than "fill this rectangle".

The other alternative is to skip painting anything that will be covered. That
is a real optimisation, called occlusion culling, and browsers do a limited
version of it. It requires knowing what is opaque, which `background:
rgba(0,0,0,0.5)` immediately complicates, so the general case remains: paint
everything, in order, and accept the overdraw.

## Check yourself

`z-index` lets an element be painted in front of one that comes after it in
the document. Where does that fit into a single ordered walk?

It does not, and that is why stacking contexts exist. An element with a
`z-index` (and a `position` other than `static`) creates a
*stacking context*. Its subtree is painted as a unit, and the units are sorted
by `z-index` before being painted in that order.

So the walk is still ordered, but the order is a sort rather than document
order, and the sort is over groups rather than elements. That is why a child
can never escape its parent's stacking context, no matter how large its
`z-index` is. It is one of the more surprising things about CSS until you know
that painting works this way.

## If you have written C

The fill loop is the one from any framebuffer, and the performance notes are
the familiar ones. Write whole rows rather than individual cells, so the
compiler can vectorise. Keep the buffer row-major, so the writes are
sequential.

The specific hazard here is the bounds check. A box with a negative position,
or a width larger than the canvas, is not a corner case. It is normal. A
stylesheet can produce one trivially, and content that overflows its container
does it constantly. C code that computes `row * width + col` and writes
without clamping has a stylesheet-controlled out-of-bounds write, which is as
bad as it sounds. The version above clamps per cell, which is slow and
obviously correct. Production code clamps the rectangle once and then writes
without checking, which is fast and requires the clamp to be right.

Next: the scripting engine, and then the pipeline end to end.
