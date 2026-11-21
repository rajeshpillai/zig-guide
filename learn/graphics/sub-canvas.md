# A Canvas Is a View

> Four fields, not a slice. Each routine draws inside a region, and the routine does not know that the canvas is a region.

Until now, each drawing routine in this section assumed that it owned the full buffer. The type says so. There is one width, and the width is a constant. The pixel at the end of a row is immediately before the pixel at the start of the next row.

Frequently you want to draw into a region of the buffer instead. Examples are a panel inside a window, a cell inside a chart, or a widget inside a toolbar. The region has its own origin and its own edges, and these are different from the origin and the edges of the buffer. You have two choices:

- Give an offset and a clip rectangle to each routine, and apply them in each routine.
- Change the value that each routine gets.

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

/// These four fields make a canvas different from a slice.
///
/// `width` and `height` give the size of this region. `stride` gives the
/// distance between two vertically adjacent pixels **in the buffer that
/// holds them**. That distance is the full width of the parent. The width of
/// this region does not change it. A region works only if these two values
/// stay separate.
///
/// Without `stride`, a routine can only address pixels with
/// `y * width + x`. That address is correct only for a canvas that owns the
/// full buffer.
const Canvas = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    stride: usize,

    /// For a canvas over a full buffer, you cannot see the difference: the
    /// stride is equal to the width.
    fn init(pixels: []u32, w: usize, h: usize) Canvas {
        return .{ .pixels = pixels, .width = w, .height = h, .stride = w };
    }

    /// A window onto a part of this canvas. The window shares the memory of
    /// this canvas, and the function copies nothing. The child does not know
    /// its position. The child has no x or y, thus a drawing routine has no
    /// parent coordinate that it can get wrong.
    fn sub(self: Canvas, x: usize, y: usize, w: usize, h: usize) Canvas {
        const cx = @min(x, self.width);
        const cy = @min(y, self.height);
        const cw = @min(w, self.width - cx);
        const ch = @min(h, self.height - cy);

        // Here a slice cannot describe the shape of the data. A rectangle
        // inside a wider buffer is not contiguous. Thus no `[]u32` can
        // describe exactly these pixels. This slice starts at the first pixel
        // of the region and ends at the last pixel of its bottom row. Each gap
        // between two rows belongs to the parent. The length is only a bound
        // on the buffer.
        const span = if (ch == 0) 0 else (ch - 1) * self.stride + cw;

        return .{
            .pixels = self.pixels[cy * self.stride + cx ..][0..span],
            .width = cw,
            .height = ch,
            .stride = self.stride,
        };
    }

    /// This clip protects the parent. `width` and `height` belong to this
    /// region. Thus the clip rejects only pixels that the region does not own.
    /// The clip rejects these pixels also when the slice above permits the
    /// write.
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

/// Ten characters, from dark to light. The other chapters in this section use
/// the same ramp for their dumps. Thus you can compare these pictures with
/// those pictures.
const ramp = " .:-=+*#%@";

fn dump(canvas: Canvas, out: *std.Io.Writer) !void {
    var row: [root_width]u8 = undefined;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            // Use `stride`, not `width`. With `width` here, a view reads the
            // wrong pixels.
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

    // Two panels side by side, and one panel two levels deep. The same `fill`
    // that filled the full screen also fills each panel.
    const left = root.sub(2, 2, 26, 14);
    const right = root.sub(32, 2, 26, 14);
    left.fill(amber);
    right.fill(green);

    const inset = right.sub(3, 3, 14, 6);
    inset.fill(paper);

    // A bar 40 wide inside a panel that is 26 wide. The parent does not
    // change. The clip in `set` rejects each column past the edge of the
    // panel. Thus the bar stops at the border of the panel. The bar does not
    // go into the panel next to it.
    left.rect(4, 5, 40, 3, violet);

    try out.writeAll("the whole framebuffer\n");
    try dump(root, out);

    // The same pixels, addressed as a region. The program copies nothing. The
    // dump reads the memory of the parent through different bounds.
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

**The bar is 40 pixels wide inside a panel that is 26 pixels wide.** The bar stops at the edge of the panel. The program does not change the panel next to it. Neither `rect` nor the caller refers to the position of the panel to get this result.

**The three sub-canvases share one buffer and one stride with the root.** The table at the end shows this in four rows. `width` is different for each region. `stride` is 60 for all of them, and also for the region two levels deep. All of the canvases address the same memory, and the shape of that memory did not change.

**The child does not know its position.** `Canvas` has no `x` and no `y`. A sub-canvas is its pixels, its size, and the distance between its rows. A drawing routine needs nothing more. The canvas stores no parent coordinate, thus no routine can forget to add a parent coordinate.

**The dump of the right panel copied nothing.** The second picture is the same memory as the first picture. The program reads that memory through different bounds.

## The stride gives what the width cannot give

For a canvas over a full buffer, the stride and the width are the same number. Thus the earlier chapters did not need to tell them apart. When a canvas is a region, the two numbers are different. In a region, the pixel below a pixel is one full buffer row after it. The width of the region does not set that distance.

Thus the addressing has two parts:

- `width` and `height` give the bounds of the region: what the region *is*.
- `stride` gives the *spacing* of the rows.

With the width as the stride, each row after the first starts a small distance to the left of the row above. The picture shears diagonally across the screen. The result looks like a bug in the drawing code, but the bug is in the addressing.

## A rectangle is not a slice

Zig asks a question here that C does not ask.

`sub` must return a `[]u32`, and no `[]u32` describes exactly these pixels. A rectangle inside a wider buffer is not contiguous. The returned slice starts at the first pixel of the region and ends at the last pixel of its bottom row. Thus the slice covers the region, and also the gap at the end of each row. That gap belongs to the parent.

That bound gives less protection than it appears to give. If an index is past the end of the framebuffer, the bounds check catches the error. If code writes into the panel next to the region, nothing catches the error, because those pixels are inside the slice.

The clip in `set` keeps the panels apart. The clip compares against the `width` and the `height` of the region. Thus two different mechanisms give two different guarantees, and only the bounds check comes from the language. If you do not use `set` and you index `pixels` directly, you keep the bounds check. But you lose the clip that keeps the drawing inside the region.

## Check yourself

The slice contains pixels that the region does not own. What stops `fill` from a write to those pixels?

`fill` calls `set`, and `set` rejects each `x` that is equal to or more than `width`. The pixels in the gap are at the end of a row. To get to one of them, a call must give an `x` past the right edge of the region. `set` refuses exactly this case. You can get to the pixels through the slice, but not through the API.

The protection comes from one comparison in `set`, and a person wrote that comparison by hand. The slice bound and the type do not give this protection. When a widget paints over the widget next to it, examine that comparison first.

## If you know C

This struct is `Olivec_Canvas` from [olive.c](https://github.com/tsoding/olive.c), the 2D graphics library of Alexey Kutepov that has no dependencies. Each field is the same, and `sub` is `olivec_subcanvas`. The C version has a bare pointer with no length. Thus the bounds check above does not exist. Only the clip stops a widget from a write over the other parts of the window.

If the comparison in the clip is wrong, the code writes into the pixels of a different widget and gives no error. The symptom is a smear in a part of the screen where the code is correct.

The same design also occurs outside graphics libraries. A GUI toolkit gives a widget a region for its paint, and a stride that the widget does not own. A compositor gives a client a buffer with a stride that the client did not select. Usually the compositor rounds the stride up for alignment. This is the common case where the stride is larger than the width for a canvas that is not a sub-canvas.

Next: read pixels from one canvas, and paint them onto a different canvas.
