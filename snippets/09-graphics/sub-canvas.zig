//! title: A Canvas Is a View
//! Four fields, not a slice. Each routine draws inside a region, and the routine does not know that the canvas is a region.

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
