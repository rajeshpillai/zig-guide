# Layout

> The parent gives each child its width. The children add up to the height of the parent.

After two chapters, the program has a tree of nodes and a way to ask how each node must look. Neither of them tells where each node goes. Layout is the stage that changes the tree into rectangles with positions. The earlier stages parse text. Layout is the first stage of a browser that calculates geometry.

The algorithm is not symmetric:

- **Width goes down.** A block fills the width that it gets. Thus a parent can decide the widths of its children before it knows anything about them.
- **Height goes up.** A block is as tall as its contents. Thus a parent cannot know its height until the layout of each child is complete.

One pass goes down for the widths, and one pass goes up for the heights. Many surprises in CSS sizes come from this difference.

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

/// Each line of text has this height. A real engine measures the font and
/// breaks the text into lines that fit the width. The number of lines gives
/// the height. That is inline layout. It is a different algorithm from the
/// block layout below.
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

    /// Pass one goes down. The parent decides the width of a block, because a
    /// block fills the space that it gets. The pass does not look at the
    /// children. Thus this pass can run before the children exist.
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

    /// Pass two goes up. The height of a block is the height that its children
    /// need. The pass cannot know that height before the layout of the children.
    /// The pass gives positions on the way down, and adds heights on the way up.
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
    // Format each number into a string first, then add the padding. If an
    // integer has a width, this compiler prints a sign with it (`{d:<4}` on 7
    // is "+7  "). A box tree must not show a column of plus signs.
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

**The widths become smaller at each level: 400, then 380, then 360.** The viewport gives 400. `#page` has a padding of 10 on each side, thus its content is 380. `.box` is inside `#page`, and it has a margin of 5 and a padding of 5. These use 20 more, thus the children of `.box` get 360. The pass did not look at a child at any point.

**The heights add up from the bottom.** The two paragraphs inside `.box` are 20 each, thus `.box` is 40. `#page` contains these boxes:

- an `h1` that is 40 tall
- the `.box`, which is 40 tall, with a margin of 5 and a padding of 5 on each side
- a footer that is 20 tall

40 plus 60 plus 20 is 120. No part of the program can know this number before the layout of the children.

**The `h1` has an explicit height of 40, and it kept that height.** Its text is 20 tall. An explicit height overrides the measured height. Thus content can overflow a box, and that is the reason for the `overflow` property.

**The positions come from a cursor.** The program puts each child at the current y. Then the cursor moves down by the full outer height of that child. This one loop is normal flow. It is the reason that blocks stack vertically by default.

## Why `height: 100%` does not do what people expect

`width: 100%` works because the widths go down. The width of the parent is already known when the program calculates the size of the child.

`height: 100%` asks the child to be as tall as its parent. But the program calculates the height of the parent *from its children*. The question is circular. CSS says that the question has no answer, unless the parent has a definite height of its own. When there is no answer, the browser ignores the declaration.

Thus the usual fix is an explicit height on each ancestor. Viewport units also work, because the viewport has a definite height. That height does not depend on the contents of the viewport.

## What this leaves out

**Inline layout.** In this program, text is always one line that is 20 pixels tall. A real engine measures the text in its font and breaks the text into lines that fit the width. The number of lines gives the height. Inline layout is a different algorithm, and it runs inside the block algorithm. In inline layout, the whitespace that the [HTML chapter](https://www.ziglang.in/learn/browser/html/) discarded becomes important.

**All layout that is not normal flow.** Floats, absolute positions, flexbox and grid are each a different layout algorithm. `display` and `position` select the algorithm for each element. Flexbox reverses the asymmetry above. That is the reason flexbox solved problems that were difficult for ten years.

## Check yourself

The program runs `buildWidths` to the end, then runs `placeAndSize` to the end. Why can the program not use one pass?

The height of a parent needs the heights of its children. The width of a child needs the width of its parent. One pass would have to move in both directions at the same time. Two passes in opposite directions make each pass simple.

Real engines run both passes, and they call the two passes together *reflow*. The heights go up. Thus, a change to the height of one element causes a new calculation for each ancestor in the chain.

A script can change the document, and then the old boxes are out of date. The browser tries to run layout again one time for each frame, not one time for each change.

When JavaScript reads a computed size, such as `offsetHeight`, the browser cannot follow that plan. The browser cannot answer from boxes that are out of date. It must run layout *immediately*, in the middle of your script.

If a loop reads a size and also writes to the page, each iteration causes a full layout. This problem has the name *layout thrashing*. It is the same two passes from this chapter. They run a thousand times, because the script asks a thousand questions.

## If you know C

The walk through the tree is simple. The arithmetic needs care. Each value here is a signed integer, and the box model adds values together.

A negative margin is a real CSS feature, and it makes a box wider than its parent. A chain of negative margins can make a width negative. A production engine clamps the value at zero after each subtraction.

Layout is also the hot path. A page has tens of thousands of boxes. Layout runs on each resize, on each animation frame that changes the geometry, and on each DOM change. Thus engines pack their box structs, and they cache the result for each node with a dirty bit.

The flat array in this program also helps the speed. When layout walks a tree of pointers to random locations on the heap, layout is slower.

Next: paint, which changes these rectangles into pixels.
