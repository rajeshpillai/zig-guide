# Paint

> A rectangle of memory, filled from back to front. The last write wins.

Layout made rectangles with positions. The paint stage fills them in. It is the simplest stage in the pipeline.

The canvas is a rectangle of memory. Each box writes its colour into the cells that it covers. The painter visits the parents first, then the children in document order. Thus a box that the painter paints later covers the previous contents. The painter does not use a depth buffer or a visibility test. It does not clip a box against the boxes that are already on the canvas.

This method is the **painter's algorithm**. A painter on a canvas paints the later layers over the earlier layers, and this algorithm does the same. It is the correct choice here, because the order is already known. The document tells which element is in front of which element.

## The program

```zig
const std = @import("std");
const dom = @import("html.zig");
const style = @import("css.zig");
const layout = @import("layout.zig");

pub const cols = 50;
pub const rows = 15;

/// The framebuffer. A real framebuffer holds four bytes for each pixel, and
/// the browser gives it to the compositor. This one holds one character for
/// each cell, so that you can read the result in a terminal. Nothing else
/// about the algorithm changes.
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

/// Parents first, then children, in document order. That order is the
/// painter's algorithm: paint all boxes, and a box painted later covers the
/// previous contents. There is no depth test, and the painter does not clip
/// a box against another box. The only clip is at the edges of the canvas.
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
        // Paint the characters of the text. Clip them to the edges of the canvas.
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

**The program made three fills and wrote three runs of text, in order. You can see the order in the picture.**

1. `#page` filled its area with `-`.
2. `h1` filled a part of that area with `=`.
3. `.box` filled a lower part with `o`.
4. The program wrote the text over the fills.

The paragraphs have no `background` rule, thus they did not fill. Each step wrote over the step before it, and nothing did a check first.

**The canvas is an array.** A real framebuffer has four bytes for each pixel, not one character. The fill loop writes RGBA instead of a letter. The remainder of the structure is the same. The [pixel buffers](https://www.ziglang.in/learn/graphics/pixel-buffers/) chapter builds the full version.

**Clipping is a bounds check.** Each write tests if the cell is inside the canvas. The check stops a box that is off the edge, so that the box cannot write outside the buffer. Without the check, a stylesheet could cause a buffer overflow.

**The program paints text, but it does not do a layout of the text.** The text starts at the corner of the box and continues to the right. Real text needs glyphs from a font at a size, with hinting and subpixel positioning. The [font](https://www.ziglang.in/learn/graphics/) work in the graphics section is closer to that.

## Why this order and not another

One alternative is to paint the children first, and then let the parents fill the area around them. That alternative fails immediately. The background of a parent would need the combined shape of all its children. That question is much more difficult than "fill this rectangle".

The other alternative is to skip each part that a later box will cover. That is a real optimisation, with the name occlusion culling. Browsers do a limited version of it. It needs to know which boxes are opaque, and `background: rgba(0,0,0,0.5)` makes that more difficult. Thus the general case stays the same: paint all boxes in order, and accept that the program paints some pixels two times.

## Check yourself

With `z-index`, the browser can paint an element in front of an element that comes after it in the document. How does `z-index` fit into one ordered walk?

It does not fit. Stacking contexts solve this problem. An element with a `z-index`, and with a `position` that is not `static`, makes a *stacking context*. The browser paints the subtree of that element as a unit. It sorts the units by `z-index`, then paints them in that order.

Thus the walk is still ordered. But the order comes from a sort, not from the document, and the sort is over groups, not single elements. For this reason, a child can never paint outside the stacking context of its parent, however large its `z-index` is. This surprises many people, until they know how the paint stage works.

## If you know C

The fill loop is the same as in any framebuffer, and so are the notes about performance:

- Write full rows instead of single cells, so that the compiler can vectorise the loop.
- Keep the buffer row-major, so that the writes are sequential.

The main danger here is the bounds check. A box with a negative position, or a width larger than the canvas, is normal, not a corner case. A stylesheet can make one easily. Content that overflows its container does it all the time.

C code that calculates `row * width + col` and writes without a clamp lets a stylesheet control an out-of-bounds write. That is a serious security bug.

The version above clamps each cell. It is slow, and it is clearly correct. Production code clamps the rectangle one time and then writes without a check. That method is fast, but the clamp must be correct.

Next: the scripting engine, and then the full pipeline from start to end.
