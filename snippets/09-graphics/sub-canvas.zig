//! title: A Canvas Is a View
//! Four fields instead of a slice, and every routine draws inside a region without knowing it is one.

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
