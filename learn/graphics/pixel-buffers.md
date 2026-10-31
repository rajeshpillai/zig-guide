# A Framebuffer Is an Array

> Row-major layout, top-left origin, packed pixels, and a putPixel that clips.

This section uses no graphics library. Code that you can read sets each pixel. Between the code and an image, there is only a block of numbers and a decision about how to interpret the numbers.

The decision has three parts:

- **Row-major.** Pixel `(x, y)` is at `y * width + x`. A row is contiguous, and the next row starts immediately after it.
- **Top-left origin.** `y = 0` is the top row, and `y` increases downward. Almost all display APIs use this rule. It is upside down from the rule that you learned in maths, and you will probably make this mistake at least one time.
- **One value per pixel.** These chapters use a `u32` that holds `0x00RRGGBB`, because X11 and Wayland want this format in a client buffer. When you write full `u32` values, the byte order is also correct without more work. On a little-endian computer, the value is in memory as B, G, R, X.

```zig
const std = @import("std");

const width: usize = 64;
const height: usize = 32;

// Global, not local. At 64x32 the array fits in all stacks. At 640x480 the
// same array is 1.2 MB. The default thread stack is 8 MB on Linux, 1 MB on
// Windows, and much less on some embedded targets. Thus a picture on the stack
// can overflow the stack on a different platform. Make the picture global, or
// allocate it on the heap.
//
// `undefined` is safe only because `drawGradient` below writes each cell.
// A partial scene must start from a known fill. If it does not, the image
// contains the old data that was in memory.
var pixels: [width * height]u32 = undefined;

/// Pack three channels into `0x00RRGGBB`.
fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// Row-major: pixel (x, y) is at `y * width + x`. The rows are contiguous, one
/// after the other, and y = 0 is the *top* row.
fn index(x: usize, y: usize) usize {
    return y * width + x;
}

// The coordinates are signed because callers get them by subtraction. Half of
// these results are negative. In `usize`, a negative result underflows to a
// very large number. In Debug the result is a panic. In the other modes the
// result is a wrong answer.
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
            // Multiply before you divide. `(x / (width - 1)) * 255` is zero in
            // all columns but the last, because integer division truncates.
            // The divisor is `width - 1`, not `width`, thus the last column
            // gets exactly 255.
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(@intCast(x), @intCast(y), rgb(r, g, 80));
        }
    }
}

// Ten characters, from dark to light, one per pixel. The section uses them to
// show a picture in a pane that has only text. A real program gives the same
// buffer to a file or a display server.
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

`640 * 480 * 4` is 1.2 MB. The default thread stack is 8 MB on Linux and 1 MB on Windows. On some embedded targets, the stack is smaller. A full-size image in a local variable can work on one computer and overflow the stack on a different computer. Make the image global, or allocate it on the heap.

`undefined` is safe here only because `drawGradient` writes each cell before the program reads a cell. A scene that fills only part of the buffer must start from a known colour. If it does not, the image contains the old data that was in memory.

## Two arithmetic errors

```zig
const r: u8 = @intCast((x * 255) / (width - 1));
```

**Multiply before you divide.** `(x / (width - 1)) * 255` is zero in all columns but the last, because integer division truncates. This is a common bug in integer scaling code. You cannot see the bug until you look at the output.

**Use `width - 1`, not `width`.** With `width`, the last column does not reach the end value: at a width of 64, the value is 251, not 255. In a gradient, nobody sees the difference. When the value is an index, the difference is important.

This section uses no floats, unless a chapter says otherwise. Integers are exact for this work. Exact values help you when you read pixel values to debug a program.

## Why putPixel takes signed coordinates

A shape gets the coordinates of its pixels by subtraction: a circle from its centre, a line from its start. Half of these results are negative. In `usize`, a negative result underflows to a very large number. In Debug mode the result is a panic, and in the other modes the result is a wrong answer. Coordinates that can be negative need a signed type. The cost is an `@intCast` where the program uses the value.

The bounds check in `putPixel` does more than make the code safe. It is **clipping**. When a request for an off-screen pixel is legal, a shape routine does not need special code for the edges. Thus the circle in [Circles](../circles/) has only a few lines, even when the circle goes past two sides of the buffer at the same time.

`putPixel` is also a slow way to draw. A real renderer writes full spans of a row at a time. The reason is that a call and a bounds check for each pixel are most of the cost. `putPixel` is good for learning, but it is too slow for a hot loop.

## Why the output is text

The pages here run in your browser through the same WASI shim as all other snippets in this guide. The shim gives a program stdout and an empty working directory, but no window. Thus the program prints the buffer. Each pixel is one character, selected by luminance from a ramp of ten characters.

A chapter that needs real colour also writes the buffer to a PPM file in that directory. The page paints, under the text, each `.ppm` file that the program leaves in the directory. The program prints one line for each file, with a hash of its pixels:

```
wrote triangle.ppm: 64x32, fnv1a d62c1083
```

CI compares the file with that line, and compares the line with the expected output. Thus CI checks the picture that you see in the same way as it checks the text.

The program does not resample the image. The canvas is 64x32 and the text is 64 characters wide. Thus the characters that you count on screen are the pixels that the code wrote. The chapters after this one share the text output through a helper module:

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

The file is `snippets/09-graphics/_canvas.zig`. Because of the underscore at the start of the name, the build does not use the file as a chapter.

## The next chapters

The order is: put pixels into a buffer, move the buffer out of the process, then draw useful shapes.

- [Write an Image File](../image-files/) writes the buffer to disk as a PPM.
- [Lines](../lines/) and [Circles](../circles/) are the first two primitives of each rasterizer.
- [Alpha Blending](../blending/) is for when a later write must not fully replace an earlier write.
- [Rasterize Triangles](../triangles/) is about the primitive that a GPU really draws.
- [Antialiasing](../antialiasing/) changes a hard edge into a coverage value.
- [Onto the Screen](../on-screen/) gives the same buffer to a display server.
