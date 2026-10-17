# Layout

> Widths flow down from the parent. Heights add up from the children.

Two chapters in, there is a tree of nodes and a way to ask what each one
should look like. Neither says where anything goes. Layout is the stage that
turns that into rectangles with positions. It is the first part of a browser
that does geometry instead of parsing.

The algorithm is not symmetric:

- **Width flows down.** A block fills the width it is given, so a parent can
  decide its children's widths before it knows anything about them.
- **Height flows up.** A block is as tall as its contents, so a parent cannot
  know its own height until every child has been laid out.

There is one pass downward for widths and one pass upward for heights. Many
surprises in CSS sizing come from this difference.

## The program

```zig
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
/// the text into lines that fit the width, and the height follows from how
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
    // a box tree should not show a column of plus signs.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.layout`)*

## What just happened

**Widths narrow going down: 400, then 380, then 360.** The viewport gives 400.
`#page` has 10 of padding on each side, so its content is 380. `.box` inside
it has 5 of margin and 5 of padding, taking 20 more, so its children get 360.
No child was consulted at any point.

**Heights accumulate going up.** The two paragraphs inside `.box` are 20 each,
so `.box` is 40. `#page` contains a 40-tall `h1`, then that box at 40 tall plus
5 of margin and 5 of padding on each side, and a 20-tall footer: 40 plus 60
plus 20 is 120. Nothing could have known that before laying the children out.

**`h1` was given an explicit height of 40 and kept it.** Its text is 20 tall.
An explicit height overrides the measured one. This is how content can
overflow a box, and it is why the `overflow` property exists.

**Positions come from a running cursor.** Each child is placed at the current y
and then the cursor moves down by that child's full outer height. This one
loop is normal flow. It is why blocks stack vertically by default.

## Why `height: 100%` disappoints people

`width: 100%` works because widths flow down: the parent's width is already
known when the child is sized. `height: 100%` asks the child to be as tall as
its parent, but the parent's height is computed *from its children*. The
question is circular. CSS defines it as having no answer unless the parent has
a definite height of its own, and when there is no answer the declaration is
ignored.

So the usual fix is to give every ancestor an explicit height. Viewport units
also work. The viewport has a definite height that
does not depend on anything inside it.

## What this leaves out

**Inline layout.** Text here is one 20-pixel line, always. A real engine
measures the text in its font, breaks it into lines that fit the width, and
gets the height from the number of lines. That is a separate algorithm that
runs inside the block one. It is also where the whitespace that the [HTML
chapter](https://www.ziglang.in/learn/browser/html/) discarded starts to matter.

**Everything that is not normal flow.** Floats, absolute positioning, flexbox
and grid are each their own layout algorithm, chosen per element by `display`
and `position`. Flexbox reverses the asymmetry above. That is why it solved
problems that had been awkward for a decade.

## Check yourself

The program runs `buildWidths` completely, then `placeAndSize` completely. Why
can it not be one pass?

Because a parent's height needs its children's heights, and a child's width
needs its parent's width. One pass would have to move in both directions at
once. Splitting into two passes with opposite directions is what makes each
one simple.

Real engines run both passes and call the whole thing *reflow*. Because
heights flow up, a change to one element's height forces a recomputation up
the whole ancestor chain.

A script can change the document, and then the old boxes are out of date.
The browser tries to run layout again once per frame, not once per change.
Reading a computed size from JavaScript, like `offsetHeight`, breaks that plan.
The browser cannot answer from out-of-date boxes. It must run layout *right
now*, in the middle of your script. If a loop reads a size and also writes to
the page, every iteration forces a full layout. This is called *layout
thrashing*. It is the same two passes from this chapter, run a thousand times
because the script asked a thousand questions.

## If you have written C

The tree walk is simple. The arithmetic needs the care. Every value here is a
signed integer, and the box model adds values together. A negative margin is a
real CSS feature, and it makes a box wider than its parent. A chain of them
can make a width negative. A production engine clamps at zero
after every subtraction.

Layout is also the hot path. A page has tens of thousands of boxes. Layout
runs on every resize, every animation frame that changes geometry, and every
DOM change. So engines pack their box structs, and they cache the result per
node with a dirty bit. The flat array used here also helps speed. Walking a
tree of pointers scattered across the heap makes layout slower.

Next: turning these rectangles into pixels.
