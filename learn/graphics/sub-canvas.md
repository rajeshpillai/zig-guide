# A Canvas Is a View

> Four fields instead of a slice, and every routine draws inside a region without knowing it is one.

Every drawing routine in this section so far has assumed it owns the whole
buffer. The type says so. There is one width, it is a constant, and the pixel
at the end of a row is followed by the pixel at the start of the next.

A panel inside a window. A cell inside a chart. A widget inside a toolbar. The
region has its own origin and its own edges, and the buffer underneath it does
not. You can pass an offset and a clip rectangle to every routine and add them
in every routine, or you can change what a routine is given.

## The program

```zig
const std = @import("std");

const root_width: usize = 60;
const root_height: usize = 18;

var framebuffer: [root_width * root_height]u32 = undefined;

fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

const backdrop = rgb(40, 44, 52);
const amber = rgb(247, 164, 29);
const green = rgb(63, 185, 80);
const paper = rgb(240, 246, 243);
const violet = rgb(120, 60, 180);

/// The four fields that make a canvas something other than a slice.
///
/// `width` and `height` say how big this region is. `stride` says how far apart
/// two vertically adjacent pixels are **in the buffer that actually holds
/// them**, which is the parent's full width and has nothing to do with this
/// region's. Splitting those two apart is the entire idea: without `stride`,
/// `y * width + x` is the only addressing a routine can do, and it is only
/// correct for a canvas that owns the whole buffer.
const Canvas = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    stride: usize,

    /// A canvas over a whole buffer is the case where the distinction does not
    /// show: its stride is its width.
    fn init(pixels: []u32, w: usize, h: usize) Canvas {
        return .{ .pixels = pixels, .width = w, .height = h, .stride = w };
    }

    /// A window onto part of this canvas, sharing its memory. Nothing is
    /// copied, and the child is not told where it sits: it has no x or y, so
    /// there is no parent coordinate for a drawing routine to get wrong.
    fn sub(self: Canvas, x: usize, y: usize, w: usize, h: usize) Canvas {
        const cx = @min(x, self.width);
        const cy = @min(y, self.height);
        const cw = @min(w, self.width - cx);
        const ch = @min(h, self.height - cy);

        // Here is where a slice stops fitting the shape of the thing. A
        // rectangle inside a wider buffer is not contiguous, so no `[]u32` can
        // describe exactly these pixels: this one runs from the region's first
        // pixel to the last pixel of its bottom row, and every gap between one
        // row and the next belongs to the parent. The length is a bound on the
        // buffer, not a description of the region.
        const span = if (ch == 0) 0 else (ch - 1) * self.stride + cw;

        return .{
            .pixels = self.pixels[cy * self.stride + cx ..][0..span],
            .width = cw,
            .height = ch,
            .stride = self.stride,
        };
    }

    /// The clip that actually protects the parent. `width` and `height` are
    /// this region's, so a pixel rejected here is one the region does not own,
    /// whether or not the slice above would have allowed the write.
    fn set(self: Canvas, x: usize, y: usize, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.stride + x] = color;
    }

    fn fill(self: Canvas, color: u32) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| self.set(x, y, color);
        }
    }

    fn rect(self: Canvas, x: usize, y: usize, w: usize, h: usize, color: u32) void {
        for (0..h) |row| {
            for (0..w) |col| self.set(x + col, y + row, color);
        }
    }
};

/// Ten characters, dark to light, the same ramp the rest of this section dumps
/// with, so these pictures can be read against those.
const ramp = " .:-=+*#%@";

fn dump(canvas: Canvas, out: *std.Io.Writer) !void {
    var row: [root_width]u8 = undefined;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            // `stride`, not `width`. This one line is the difference between a
            // view that works and one that reads the wrong pixels.
            const color = canvas.pixels[y * canvas.stride + x];
            const luma = (((color >> 16) & 0xff) * 77 +
                ((color >> 8) & 0xff) * 150 +
                (color & 0xff) * 29) >> 8;
            row[x] = ramp[(luma * (ramp.len - 1)) / 255];
        }
        try out.writeAll(row[0..canvas.width]);
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const root = Canvas.init(&framebuffer, root_width, root_height);
    root.fill(backdrop);

    // Two panels side by side, and one nested two levels deep. Every one of
    // them is filled by the same `fill` that just filled the whole screen.
    const left = root.sub(2, 2, 26, 14);
    const right = root.sub(32, 2, 26, 14);
    left.fill(amber);
    right.fill(green);

    const inset = right.sub(3, 3, 14, 6);
    inset.fill(paper);

    // 40 wide inside a panel that is 26 wide. The parent is untouched: the
    // clip in `set` rejects every column past the panel's own edge, so the bar
    // stops at the panel border instead of running into the one beside it.
    left.rect(4, 5, 40, 3, violet);

    try out.writeAll("the whole framebuffer\n");
    try dump(root, out);

    // The same pixels, addressed as a region. Nothing was copied to produce
    // this; it is the parent's memory, read through different bounds.
    try out.writeAll("\nthe right panel alone, same memory\n");
    try dump(right, out);

    try out.writeAll("\n           width  height  stride\n");
    const rows = [_]struct { name: []const u8, canvas: Canvas }{
        .{ .name = "root", .canvas = root },
        .{ .name = "left", .canvas = left },
        .{ .name = "right", .canvas = right },
        .{ .name = "inset", .canvas = inset },
    };
    for (rows) |r| {
        try out.print("{s:<10}{d:>6}{d:>8}{d:>8}\n", .{
            r.name,
            r.canvas.width,
            r.canvas.height,
            r.canvas.stride,
        });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.sub-canvas`)*

## What just happened

**The bar is 40 pixels wide inside a panel 26 wide.** It stops at the panel's
edge. The panel beside it is untouched, and neither `rect` nor the caller
mentions the panel's position to make that happen.

**Three canvases, one buffer, one stride.** The table at the end is the whole
idea in four rows. `width` differs for each region. `stride` is 60 for all of
them, including the one nested two levels deep, because all of them address
the same memory and that memory has not changed shape.

**The child does not know where it is.** `Canvas` has no `x` and no `y`. A
sub-canvas is its pixels, its size, and the distance between its rows, and
that is genuinely all a drawing routine needs. There is no parent coordinate
to forget to add, because there is no parent coordinate.

**Dumping the right panel copied nothing.** The second picture is the same
memory as the first, read through different bounds.

## Stride is what width cannot say

For a canvas over a whole buffer, stride and width are the same number, which
is why the distinction can stay hidden for an entire section. They come apart
the moment a canvas is a region. The pixel below one in a region is one full
buffer row further on, and the region's own width has nothing to do with how
far that is.

So the addressing splits in two. `width` and `height` bound what the region
*is*. `stride` says how its rows are *spaced*. Use the same value for both, and every row after the first lands progressively
further left. That draws a picture which shears diagonally across the screen.
It looks like a bug in whatever you were drawing, rather than in the
addressing.

## A rectangle is not a slice

This is where Zig asks a question C does not.

`sub` has to hand back a `[]u32`, and no `[]u32` describes exactly these
pixels. A rectangle inside a wider buffer is not contiguous. The slice
returned runs from the region's first pixel to the last pixel of its bottom
row. So it spans the region, and the gap at the end of each row belongs to the
parent: It is worth being exact about what it buys, because it is easy to
assume it buys more. Indexing past the end of the framebuffer is caught.
Writing into the panel next door is not, because those pixels are inside the
slice.

What keeps the panels apart is the clip in `set`, comparing against the
region's own `width` and `height`. Two different guarantees, from two
different mechanisms, and only one of them is the language's. Reach past `set`
and index `pixels` directly and you keep the bounds check and lose the
containment.

## Check yourself

If the slice contains pixels the region does not own, what stops `fill` from
painting them?

`fill` goes through `set`, and `set` rejects any `x` that is at least `width`.
Those gap pixels sit at the end of a row, so reaching one means asking for an
`x` past the region's right edge, which is exactly the case `set` refuses. The
pixels are reachable through the slice and unreachable through the API, which
is the arrangement the clip exists to produce.

Note which line is doing the work. Not the slice bound, and not the type: one
comparison in `set`, written by hand. That is the part to check when a widget
paints over its neighbour.

## If you have written C

This struct is `Olivec_Canvas` from
[olive.c](https://github.com/tsoding/olive.c), Alexey Kutepov's
dependency-free 2D graphics library, field for field, and `sub` is
`olivec_subcanvas`. The C version carries a bare pointer with no length. The
bounds check discussed above does not exist at all, and the clip is the only
thing standing between a widget and the rest of the window. A wrong comparison
there writes into another widget's pixels, silently, and the symptom is a
smear in a part of the screen whose code is correct.

The same shape turns up well outside graphics libraries. A GUI toolkit hands a
widget a region to paint and a stride it does not own. A compositor hands a
client a buffer with a stride the client did not choose, usually rounded up
for alignment. That is the common case where stride is larger than width for a
canvas that is not a sub-canvas of anything.

Next: reading pixels out of one canvas to paint them onto another.
