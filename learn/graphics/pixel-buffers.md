# A Framebuffer Is an Array

> Row-major layout, top-left origin, packed pixels, and a clipping putPixel.

There is no graphics library in this section. Every pixel is set by code you
can read. The only thing between the code and an image is a block of numbers
and a decision about how to interpret it.

That decision has three parts:

- **Row-major.** Pixel `(x, y)` lives at `y * width + x`. A row is contiguous,
  and the next row starts immediately after it.
- **Top-left origin.** `y = 0` is the top row and `y` grows downward. Nearly
  every display API works this way, and it is upside down from the convention
  you learned in maths. Expect to be caught by it once.
- **One value per pixel.** These chapters use a `u32` holding `0x00RRGGBB`,
  because that is what X11 and Wayland want from a client buffer. Writing whole
  `u32`s also keeps the byte order right without thinking about it: on a
  little-endian machine that value sits in memory as B, G, R, X.

```zig
const std = @import("std");

const width: usize = 64;
const height: usize = 32;

// Global rather than a local. At 64x32 it would fit anywhere, but the same
// array at 640x480 is 1.2 MB, and the default thread stack is 8 MB on Linux,
// 1 MB on Windows, and far less on some embedded targets. A picture on the
// stack is a portability landmine; make it global or heap-allocate it.
//
// `undefined` is honest only because `drawGradient` below writes every cell.
// A partial scene must start from a known fill or it ships whatever was in
// memory.
var pixels: [width * height]u32 = undefined;

/// Pack three channels into `0x00RRGGBB`.
fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// Row-major: pixel (x, y) lives at `y * width + x`. Rows are contiguous, one
/// after another, and y = 0 is the *top* row.
fn index(x: usize, y: usize) usize {
    return y * width + x;
}

// Coordinates are signed because callers arrive at them by subtraction, and
// half of those results are negative. In `usize` that underflows to an
// enormous number, which is a panic in Debug and a wrong answer otherwise.
fn putPixel(x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[index(ux, uy)] = color;
}

fn drawGradient() void {
    for (0..height) |y| {
        for (0..width) |x| {
            // Multiply before dividing. `(x / (width - 1)) * 255` is zero in
            // every column but the last, because integer division truncates.
            // And it is `width - 1`, not `width`, so the last column reaches
            // exactly 255.
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(@intCast(x), @intCast(y), rgb(r, g, 80));
        }
    }
}

// Ten characters, dark to light, one per pixel. This is how the section shows
// a picture in a text-only pane; a real program hands the same buffer to a
// file or a display server instead.
const ramp = " .:-=+*#%@";

fn dump(out: *std.Io.Writer) !void {
    var row: [width]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixels[index(x, y)];
            const r: u32 = (p >> 16) & 0xFF;
            const g: u32 = (p >> 8) & 0xFF;
            const b: u32 = p & 0xFF;
            // Rec. 601 luma in integers, scaled by 256.
            const level = ((r * 77 + g * 150 + b * 29) >> 8) * (ramp.len - 1) / 255;
            row[x] = ramp[@intCast(level)];
        }
        try out.writeAll(std.mem.trimEnd(u8, &row, " "));
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    drawGradient();

    try out.print("buffer: {d}x{d} pixels, {d} bytes\n", .{
        width, height, @sizeOf(@TypeOf(pixels)),
    });
    try out.print("(0, 0)   -> index {d}\n", .{index(0, 0)});
    try out.print("(1, 0)   -> index {d}\n", .{index(1, 0)});
    try out.print("(0, 1)   -> index {d}  (one whole row later)\n", .{index(0, 1)});
    try out.print("(63, 31) -> index {d}  = 0x{X:0>6}\n\n", .{
        index(63, 31), pixels[index(63, 31)],
    });

    try dump(out);
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.framebuffer`)*

## Why the buffer is global

`640 * 480 * 4` is 1.2 MB. The default thread stack is 8 MB on Linux, 1 MB on
Windows, and smaller still on some embedded targets. A full-size image
declared as a local is a portability bug waiting for a different machine. Make
it global, or heap-allocate it.

`undefined` is honest here only because `drawGradient` writes every cell
before anything reads one. A scene that fills part of the buffer has to start
from a known colour, or it ships whatever was in memory.

## The two arithmetic traps

```zig
const r: u8 = @intCast((x * 255) / (width - 1));
```

**Multiply before dividing.** `(x / (width - 1)) * 255` is zero in every column
but the last, because integer division truncates. This is the most common bug
in integer scaling code, and it is invisible until you look at the output.

**`width - 1`, not `width`.** With `width` the last column stops one short of
255. Nobody sees that in a gradient. It matters the moment the value is used as
an index.

No floats appear anywhere in this section unless a chapter says otherwise.
Integers are exact for this work, and exactness is worth a lot when you are
debugging by reading pixel values.

## Why putPixel takes signed coordinates

Shapes arrive at their pixels by subtraction: a circle from its centre, a line
from its start. Half of those results are negative. In `usize` a negative
result underflows to an enormous number, which is a panic in Debug mode and a
wrong answer everywhere else. Coordinates that can go negative want a signed
type, and the `@intCast` at the point of use is the price.

The bounds check in `putPixel` is doing more than safety. It is **clipping**:
once "off-screen" is a legal thing to ask for, every shape routine can be
written without an edge case for the edges. That is why the circle in
[Circles](../circles/) is a handful of lines even when it hangs off three
sides of the buffer at once.

`putPixel` is also the slow way to draw. A real renderer writes whole spans of
a row at a time, because a per-pixel call and a per-pixel bounds check
dominate the cost. It is the right shape for learning and the wrong shape for
a hot loop.

## Why the output is text

The pages here run in your browser through the same WASI shim as every other
snippet in this guide, and that gives them stdout and nothing else. So the
buffer is printed: one character per pixel, picked from a ten-step ramp by
luminance.

Nothing is resampled. The canvas is 64x32 and the dump is 64 characters wide,
so what you count on screen is what the code wrote. The chapters after this
one share that dump through a helper module:

```zig
pub const width: usize = 64;
pub const height: usize = 32;

pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn putPixel(pixels: []u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[uy * width + ux] = color;
}
```

The file is `snippets/09-graphics/_canvas.zig`. The leading underscore is what
keeps the build from treating it as a chapter of its own.

## Where this goes

The order is: get pixels into a buffer, get the buffer out of the process,
then draw things worth looking at.

- [Writing an Image File](../image-files/) puts the buffer on disk as a PPM.
- [Lines](../lines/) and [Circles](../circles/) are the two primitives every
  rasterizer starts with.
- [Alpha Blending](../blending/) is what you do when a later write should not
  simply destroy an earlier one.
- [Rasterizing Triangles](../triangles/) is the primitive a GPU actually draws.
- [Antialiasing](../antialiasing/) turns a hard edge into a coverage value.
- [Onto the Screen](../on-screen/) hands the same buffer to a display server.
