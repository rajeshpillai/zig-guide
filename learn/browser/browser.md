# The Whole Pipeline

> Bytes, tree, styles, boxes, pixels. Five stages, in one direction.

Each stage has had a chapter. This one runs them in a row. That is worth
doing, because the pipeline is the actual answer to "how does a browser work",
and because seeing it in forty lines is different from being told it in a
diagram.

```
bytes ─► tree ─► boxes with widths ─► boxes with positions ─► pixels
        (HTML)      (CSS + layout)         (layout)            (paint)
```

Five stages, each taking only what the previous one produced. That is not
tidiness. It is the property that makes a browser possible to build at all.
The HTML parser has never heard of a pixel, and the painter has never heard of
a tag.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.browser`)*

## What just happened

**One declaration changed and the page rearranged itself.** `h1 { height: 30 }`
became `height: 60`, and everything below moved down. Nothing else in the
stylesheet or the document was touched.

That is the reason stylesheets exist, and it is worth being precise about what
made it work. The height of the box is an input to layout, and every position
below it is computed rather than stored. Change the input, run the two passes
again, get a new set of positions. There is nothing to keep in sync because
nothing was written down twice.

**The counts are printed for each render.** 11 nodes, 4 rules, 11 boxes. The box tree and the node tree happen to be the same size here. In general
they are not: some elements produce no box, and a single element can produce
several, one per line of text or one per table cell.

**Each stage is replaceable.** The renderer writes characters; swapping it for
one that writes RGBA changes nothing upstream. The layout engine does block
flow; adding flexbox means a different function producing the same `Box`
values. This is what having a pipeline buys, and it is why browsers can
rewrite one stage at a time.

## What a real browser adds, in order of how much

**Everything is incremental.** Nothing above caches anything: a second render
redoes all five stages. A real engine tracks which nodes are dirty, which
boxes need relayout, and which regions need repainting. A page is fifty
thousand nodes, and a cursor blink must not re-render it. That machinery is
larger than the pipeline it optimises.

**Everything is concurrent.** Parsing happens while bytes are still arriving.
Images decode on other threads. Painting happens on a compositor thread so
scrolling stays smooth while JavaScript is busy. The pipeline stays the same
shape; there are just several of them in flight.

The versions here are the shape of each stage with the details removed, and
the details are where the years go. The HTML parser's 80 tokenizer states.
CSS's dozen layout modes. Text shaping. Bidirectional text. And the
accumulated behaviour of thirty years of pages that must keep working.

## Check yourself

The pipeline is drawn as one direction, but a script can change the document.
What does that do to the diagram?

A script mutates the tree, which invalidates boxes, which forces layout and
paint again. The browser tries to do all of that once per frame rather than
once per change.

The failure mode has a name. Reading a computed geometry from JavaScript, like
`offsetHeight`, cannot be answered from stale boxes, so the browser must run
layout *right now*, in the middle of your script. Do that in a loop that also
writes, and every iteration forces a full layout. That is *layout thrashing*.
It is the same two-pass algorithm from the layout chapter, run a thousand
times because it was asked a thousand questions.

## Where this section ends

Six chapters. A parser that cannot fail. A cascade that decides between rules.
Two passes that turn a tree into rectangles. A painter that fills them. And a
scripting engine attached at a seam. Between them they are a browser, in the
sense that a paper aeroplane is an aircraft. The shape is right, and
everything that makes the real one hard has been left out.

If the graphics half interested you, [the graphics section](https://www.ziglang.in/learn/graphics/)
does rasterisation properly, with real pixel buffers, line and triangle
drawing, antialiasing and image files. If the language half did, [the Tiny
Language section](https://www.ziglang.in/learn/tiny-lang/lexer/) is the engine this one only
gestured at.
