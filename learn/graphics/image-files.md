# Write an Image File

> PPM, the image format that you can write without a library, and the one strict rule that is easy to break.

A buffer is useful as a picture when you can look at it. PPM is the shortest way to save a buffer: a short text header, then the pixel bytes. The format has nothing more, and it needs no library.

PPM is part of the Netpbm family. The family has six formats, on two axes: what a pixel is, and whether the data is text or binary.

| | ASCII | Binary | A pixel is |
| --- | --- | --- | --- |
| **PBM** (bitmap) | `P1` | `P4` | one bit, black or white |
| **PGM** (graymap) | `P2` | `P5` | one gray sample |
| **PPM** (pixmap) | `P3` | `P6` | three samples: R, G, B |

Write `P6`. `P3` holds the same pixels as decimal numbers in text. `P3` is larger and slower. But if you want to read your own image in an editor, it is useful to make a `P3` file one time.

## The header

```
P6\n64 32\n255\n<6144 raw bytes>
```

The header has four fields, then the data: the magic, the width, the height, and the maxval (the largest value that a sample can have). Any mix of spaces, tabs and newlines can separate the fields. Thus `P6 64 32 255 ` is as valid as the form above.

Then there is one strict rule:

> **Exactly one whitespace byte follows the maxval.** All the bytes after that single byte are pixel data.

If you write `"255\n\n"`, each pixel moves by one byte. The image shows diagonal noise. No parser can find the mistake, because `0x0A` is a legal pixel value. At the end, the snippet below decodes a file with exactly this defect, so that you can see what the reader gets.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

// The header is at most a few dozen bytes. The body is three bytes per pixel.
var file_bytes: [64 + canvas.width * canvas.height * 3]u8 = undefined;

fn drawScene() void {
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const r: u8 = @intCast((x * 255) / (canvas.width - 1));
            const g: u8 = @intCast((y * 255) / (canvas.height - 1));
            canvas.putPixel(&pixels, @intCast(x), @intCast(y), canvas.rgb(r, g, 80));
        }
    }
}

/// Write the header, then the body, and return the part of the slice that
/// the function used.
///
/// The header uses the same constants that set the size of the buffer.
/// A hardcoded "P6\n64 32\n255\n" works only until somebody changes one of
/// the constants. Then the header and the data do not agree, and the image
/// tears diagonally. No part of the program reports an error.
fn encodeP6(out: []u8) ![]const u8 {
    const header = try std.mem.print(out, "P6\n{d} {d}\n255\n", .{
        canvas.width, canvas.height,
    });

    var n = header.len;
    for (pixels) |p| {
        const c = canvas.channels(p);
        out[n + 0] = c.r;
        out[n + 1] = c.g;
        out[n + 2] = c.b;
        n += 3;
    }
    return out[0..n];
}

const Image = struct { w: usize, h: usize, data: []const u8 };

/// A reader that is sufficient for the files that this code writes. It does
/// not remove `#` comments. A general parser must remove them.
fn decodeP6(bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P6")) return error.NotP6;

    var it = std.mem.tokenizeAny(u8, bytes[2..], " \t\r\n");
    const w = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const h = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const maxval = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    if (maxval != 255) return error.UnsupportedMaxval;

    // Exactly one whitespace byte follows maxval. All the bytes after it are
    // pixel data. The tokenizer stops before that byte, thus the `+ 1`.
    const data_start = 2 + it.index + 1;
    if (data_start + w * h * 3 > bytes.len) return error.Truncated;
    return .{ .w = w, .h = h, .data = bytes[data_start..] };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    drawScene();
    const file = try encodeP6(&file_bytes);

    try out.print("total bytes: {d}\n", .{file.len});
    try out.print("header:      {d} bytes, body {d}x{d}x3 = {d}\n", .{
        file.len - canvas.width * canvas.height * 3,
        canvas.width,
        canvas.height,
        canvas.width * canvas.height * 3,
    });

    try out.writeAll("first 16:   ");
    for (file[0..16]) |b| try out.print(" {X:0>2}", .{b});
    try out.writeAll("\n");
    try out.writeAll("as text:     ");
    for (file[0..16]) |b| {
        try out.writeByte(if (b >= 0x20 and b < 0x7F) b else '.');
    }
    try out.writeAll("\n\n");

    const decoded = try decodeP6(file);
    try out.print("decoded:     {d}x{d}, {d} bytes of pixel data\n", .{
        decoded.w, decoded.h, decoded.w * decoded.h * 3,
    });
    try out.print("pixel (0,0): {d} {d} {d}\n", .{
        decoded.data[0], decoded.data[1], decoded.data[2],
    });
    const last = (canvas.width * canvas.height - 1) * 3;
    try out.print("last pixel:  {d} {d} {d}\n", .{
        decoded.data[last], decoded.data[last + 1], decoded.data[last + 2],
    });

    // One extra newline after maxval moves each pixel by one byte. No parser
    // can find this mistake, because 0x0A is a legal pixel value.
    const shifted = decodeP6("P6\n2 1\n255\n\n\x01\x02\x03\x04\x05\x06") catch unreachable;
    try out.print("shifted by one: first pixel reads {d} {d} {d}\n", .{
        shifted.data[0], shifted.data[1], shifted.data[2],
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.ppm-write`)*

## The pixel data

The pixels go from left to right and from top to bottom. There is no padding, no alignment and no row header. Each pixel is three samples in the order R, G, B.

The maxval sets the size of a sample:

- **A maxval below 256** gives one byte for each sample. `640 * 480 * 3` is 921,600 bytes.
- **A maxval from 256 to 65535** gives *two* bytes for each sample, **big-endian**. This is the only place where PPM has a byte order, and it causes bugs on little-endian computers.

With a maxval that is not 255, the samples use a different scale. With a maxval of 100, a sample of 50 is mid-gray. Use 255, unless you have a reason to use a different value.

A `#` starts a comment. The comment continues to the end of the line, and it can be at any place where whitespace can be. It is easy to write a comment, but it is difficult to read comments. A strict parser must remove the comments while it reads the header fields. Many simple parsers do this incorrectly. Thus, if the file goes to other programs, do not write comments.

## Format the header from the constants

```zig
const header = try std.mem.print(out, "P6\n{d} {d}\n255\n", .{ width, height });
```

The header uses the same `width` and `height` that set the size of the buffer. A hardcoded `"P6\n640 480\n255\n"` works only until somebody changes a constant. Then the header and the data do not agree, and the image tears diagonally. No part of the program reports an error.

## On disk

The version that writes a file does two writes: the header, then the pixels.

```zig
const std = @import("std");

const width: usize = 640;
const height: usize = 480;

// Three bytes per pixel, 921,600 bytes in total. Global, not on the stack.
var pixels: [width * height * 3]u8 = undefined;

fn putPixel(x: usize, y: usize, r: u8, g: u8, b: u8) void {
    if (x >= width or y >= height) return;
    const i = (y * width + x) * 3;
    pixels[i + 0] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
}

fn drawScene() void {
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(x, y, r, g, 80);
        }
    }

    // The circle comes second, thus it is on top. This code has no depth buffer
    // and no transparency. A later write replaces an earlier write.
    const cx: i32 = @intCast(width / 2);
    const cy: i32 = @intCast(height / 2);
    const radius: i32 = 100;
    var y: i32 = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x: i32 = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) {
                putPixel(@intCast(x), @intCast(y), 255, 220, 40);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf_out: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf_out);
    const out = &stdout.interface;

    drawScene();

    var dir = std.Io.Dir.cwd();

    // The program writes a real file, reads it again and deletes it. Thus the
    // example leaves no file on the computer that ran it.
    defer dir.deleteFile(io, "output.ppm") catch {};

    // A createFile handle is write-only by default. With `.read = true`, the
    // check at the end can read through this handle and not open the file again.
    const file = try dir.createFile(io, "output.ppm", .{ .read = true });
    defer file.close(io);

    var header_buf: [32]u8 = undefined;
    const header = try std.mem.print(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, &pixels);

    // To know that the two writes above went in the correct order, read the
    // header again. An image viewer shows the problem later. This check makes
    // the build fail now.
    var check: [15]u8 = undefined;
    _ = try file.readPositionalAll(io, &check, 0);

    try out.writeAll("header read back:\n");
    try out.writeAll(check[0..header.len]);
    try out.print("bytes on disk: {d}\n", .{header.len + pixels.len});
    try out.flush();
}

// This program runs in wasm. The runner gives it an empty working directory:
// a temporary directory in CI, and a directory in memory in your browser. In
// both, the program really writes the file and reads it again.
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.ppm-file`)*

Look at the order of the drawing. The background comes first, then the circle on top. The circle replaces the pixels that were there before. This is the painter's algorithm. Until [Alpha Blending](../blending/), it is the only compositing model in this section.

The `defer` that deletes `output.ppm` makes sure that the build that verifies this page leaves no files. When you run the program yourself, remove that one line. If you do not, the program deletes the file before you can look at it.

To look at the result, use one of these tools:

- Most Linux viewers open PPM directly (`feh output.ppm`).
- ImageMagick and the netpbm tools convert PPM to other formats:

```bash
magick output.ppm output.png
pnmtopng output.ppm > output.png
```

To examine only the header, and not the full file, use this command:

```bash
head -c 20 output.ppm | xxd
# 00000000: 5036 0a36 3430 2034 3830 0a32 3535 0a00  P6.640 480.255..
```

`5036` is `P6`. The `0a` immediately before the pixel data is the one necessary whitespace byte.

## When to use a different format

PPM is not compressed. A 4K frame is 24 MB, and a sequence of frames quickly fills a disk. PPM is the correct tool when you want to get pixels out of a program that you write. It is the wrong tool when you want to store or share the pixels. When the image is correct, convert the image, or write a PNG directly. [Write a PNG](https://www.ziglang.in/learn/graphics/png/) does this with the zlib in the Zig standard library.

Video is the exception. `ffmpeg` reads a stream of PPM files, one after the other. Thus PPM is a good pipe format for a software renderer that makes frames:

```bash
./renderer | ffmpeg -f image2pipe -i - out.mp4
```
