# Linear Light

> A stored byte is not an amount of light. Decode, mix, encode, with both tables built by the compiler.

For the colour halfway between black and white, most code writes 128. The
value 128 is half of 255. But when a screen shows 128, the screen gives about
22% of the light that it gives for 255.

The bytes in an image are not amounts of light. The bytes are an encoding of
the light. Thus decode the bytes to light, mix the light, and then encode the
result again.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Change an sRGB byte to linear light, 0.0 to 1.0. The constants 0.04045,
/// 12.92, 0.055 and 2.4 come from the sRGB standard. Do not adjust them.
fn decode(byte: u8) f64 {
    const c = @as(f64, @floatFromInt(byte)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// Change linear light, 0.0 to 1.0, to sRGB, 0.0 to 1.0. This function is the
/// inverse of `decode`.
fn encode(light: f64) f64 {
    return if (light <= 0.0031308) light * 12.92 else 1.055 * std.math.pow(f64, light, 1.0 / 2.4) - 0.055;
}

/// The program keeps linear light in 16 bits: 0 is black and 65535 is full
/// white. Eight bits are not sufficient. The dark bytes 0 to 6 would all
/// become 0.
const Light = u16;

/// One entry for each byte. A block that initialises a `const` runs at compile
/// time. Thus the program contains a table of 512 bytes, and it does not call
/// `pow` at run time.
const to_light: [256]Light = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [256]Light = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = @intFromFloat(@round(decode(@intCast(byte)) * 65535.0));
    }
    break :blk table;
};

/// The conversion from light to a byte. 65536 entries would be 64 KB. Thus the
/// index of the table is the top 12 bits of the light value. Each entry holds
/// the byte for the middle of its range of 16 light values.
const to_byte: [4096]u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [4096]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        const middle = @as(f64, @floatFromInt(i * 16 + 8)) / 65535.0;
        entry.* = @intFromFloat(@round(encode(middle) * 255.0));
    }
    break :blk table;
};

fn toLight(byte: u8) Light {
    return to_light[byte];
}

fn toByte(light: Light) u8 {
    return to_byte[light >> 4];
}

/// Mix two stored bytes directly. The weight of `a` is (n - k), and the weight
/// of `b` is k. The result rounds to the nearest byte. Most 8-bit code mixes
/// colours in this way.
fn mixBytes(a: u8, b: u8, k: u32, n: u32) u8 {
    return @intCast((@as(u32, a) * (n - k) + @as(u32, b) * k + n / 2) / n);
}

/// The same mix on light: decode, mix, encode.
fn mixLight(a: u8, b: u8, k: u32, n: u32) u8 {
    const la: u32 = toLight(a);
    const lb: u32 = toLight(b);
    return toByte(@intCast((la * (n - k) + lb * k + n / 2) / n));
}

fn mixColor(comptime mix: fn (u8, u8, u32, u32) u8, a: u32, b: u32, k: u32, n: u32) u32 {
    const ca = canvas.channels(a);
    const cb = canvas.channels(b);
    return canvas.rgb(mix(ca.r, cb.r, k, n), mix(ca.g, cb.g, k, n), mix(ca.b, cb.b, k, n));
}

/// Four bands of eight rows. Each band is a ramp from left to right.
fn drawBands() void {
    const black = canvas.rgb(0, 0, 0);
    const white = canvas.rgb(255, 255, 255);
    const red = canvas.rgb(255, 0, 0);
    const green = canvas.rgb(0, 255, 0);
    const n = canvas.width - 1;

    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const k: u32 = @intCast(x);
            const color = switch (y / 8) {
                0 => mixColor(mixBytes, black, white, k, n),
                1 => mixColor(mixLight, black, white, k, n),
                2 => mixColor(mixBytes, red, green, k, n),
                else => mixColor(mixLight, red, green, k, n),
            };
            pixels[y * canvas.width + x] = color;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.writeAll("halfway from black to white\n");
    try out.print("  mixing bytes: {d}\n", .{mixBytes(0, 255, 1, 2)});
    try out.print("  mixing light: {d}\n", .{mixLight(0, 255, 1, 2)});

    const red = canvas.rgb(255, 0, 0);
    const green = canvas.rgb(0, 255, 0);
    const by_bytes = canvas.channels(mixColor(mixBytes, red, green, 1, 2));
    const by_light = canvas.channels(mixColor(mixLight, red, green, 1, 2));
    try out.writeAll("halfway from red to green\n");
    try out.print("  mixing bytes: {d} {d} {d}\n", .{ by_bytes.r, by_bytes.g, by_bytes.b });
    try out.print("  mixing light: {d} {d} {d}\n", .{ by_light.r, by_light.g, by_light.b });

    // Byte 128 holds about 22% of the light of byte 255, not 50%.
    try out.print("light in byte 128: {d}%\n", .{(@as(u32, toLight(128)) * 100 + 32767) / 65535});

    // Each byte must return as the same byte. If the steps of the encode
    // table were too large, the dark bytes would fail this check first.
    var exact: u32 = 0;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        if (toByte(toLight(byte)) == byte) exact += 1;
    }
    try out.print("bytes that survive byte -> light -> byte: {d} of 256\n", .{exact});

    // The same conversion, but with 8-bit light instead of 16-bit light.
    var seen: [256]bool = @splat(false);
    var kept: u32 = 0;
    for (0..256) |i| {
        const light8 = (@as(u32, toLight(@intCast(i))) * 255 + 32767) / 65535;
        if (!seen[light8]) kept += 1;
        seen[light8] = true;
    }
    try out.print("distinct bytes left after 8-bit light: {d} of 256\n", .{kept});

    try out.print("tables: {d} bytes, built by the compiler\n", .{@sizeOf(@TypeOf(to_light)) + @sizeOf(@TypeOf(to_byte))});

    drawBands();
    try canvas.writePicture(init.io, out, "linear-light.ppm", &pixels);
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.linear-light`)*

## The worked example

The program finds the colour halfway from black to white in two ways:

- Mix the bytes: (0 + 255) / 2 is 128, after the program rounds the result.
- Mix the light: the average of 0% light and 100% light is 50%. When the
  program encodes 50% light again, the result is byte 188.

The output shows both values. The values 128 and 188 are very different.

The change from red to green shows the same problem in colour:

- A mix of the bytes gives `128 128 0`, a dark olive.
- A mix of the light gives `188 188 0`, a yellow.

The third and fourth bands of the picture show these two ramps.

## Why images store encoded bytes

The human eye does not see light linearly. In a dark area, a person sees a
small change much more easily than the same change in a bright area.

For this reason, the sRGB encoding gives more of its 256 values to dark tones.
Thus the steps between bytes look approximately equal to a person.

For the same reason, the first band in the picture looks even, and the second
band looks mostly pale. The second band has equal steps of light, and to the
human eye most of those steps look bright.

Thus there are two different tasks:

- To store or show a colour, use the encoded bytes.
- To add or average light, use linear values.

Blending, blurs, changes of image scale and antialiasing all add or average
light. Do these operations in linear light.

## The conversion

The sRGB standard defines the curve in two parts. Near black, the curve is a
short straight line. For the other values, the curve is a power curve.

```zig
/// Change an sRGB byte to linear light, 0.0 to 1.0. The constants 0.04045,
/// 12.92, 0.055 and 2.4 come from the sRGB standard. Do not adjust them.
fn decode(byte: u8) f64 {
    const c = @as(f64, @floatFromInt(byte)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}
```

*Quoted from the source: `decode` from `snippets/09-graphics/linear-light.zig`.*

The numbers 0.04045, 12.92, 0.055 and 2.4 come from the standard. Copy them
exactly.

A plain `x^2.2` curve is close, but the two curves are different near black.
The function `encode` uses the same curve in the opposite direction.

## Tables built by the compiler

`pow` is slow, and a byte has only 256 possible values. Thus the program
calculates all 256 answers one time and keeps the answers in a table.

```zig
/// One entry for each byte. A block that initialises a `const` runs at compile
/// time. Thus the program contains a table of 512 bytes, and it does not call
/// `pow` at run time.
const to_light: [256]Light = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [256]Light = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = @intFromFloat(@round(decode(@intCast(byte)) * 65535.0));
    }
    break :blk table;
};
```

*Quoted from the source: `to_light` from `snippets/09-graphics/linear-light.zig`.*

The code is an ordinary loop inside a block. But the block initialises a
top-level `const`. Thus Zig runs the block at compile time. The finished
program contains the 256 numbers, and it never calls `pow` for these numbers.

`@setEvalBranchQuota` increases the limit of the compiler on the quantity of
work that a compile-time block can do. `pow` has loops inside it, thus the
default limit is too low. Without the call, the build fails with an error
that names `@setEvalBranchQuota`.

## Why light needs 16 bits

The table stores light as a `u16`, not a `u8`. The output shows the result
with 8 bits.

Only 183 of the 256 bytes return as different values. The bytes 0 to 6 all
become 0. Thus seven dark greys become black.

The dark tones need small steps in linear light, because the encoding gives
many bytes to the dark tones. With 16 bits, each byte returns as the same
byte after the conversion to light and back. The output checks all 256 bytes.

## Encode light as bytes

The encode step needs a second table. If the index of the table is the full
16-bit value, the table needs 65536 entries.

Thus the index of this table is the top 12 bits. Each entry covers 16 light
values. Each entry holds the byte for the middle of its 16 light values.

```zig
/// The conversion from light to a byte. 65536 entries would be 64 KB. Thus the
/// index of the table is the top 12 bits of the light value. Each entry holds
/// the byte for the middle of its range of 16 light values.
const to_byte: [4096]u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var table: [4096]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        const middle = @as(f64, @floatFromInt(i * 16 + 8)) / 65535.0;
        entry.* = @intFromFloat(@round(encode(middle) * 255.0));
    }
    break :blk table;
};
```

*Quoted from the source: `to_byte` from `snippets/09-graphics/linear-light.zig`.*

Sixteen light values for each entry are a sufficiently small step, also near
black:

- Near black, one byte is about 20 light values wide.
- The middle of an entry is never more than 8 light values from a value that
  the entry covers.
- 8 light values are less than half a byte. Thus the rounding still gives the
  correct byte.

The round-trip line in the output is the proof. If the steps of the table
were too large, the dark bytes would fail first.

## Mix in linear light

With the two tables, a mix in linear light is two lookups, the same
arithmetic, and one more lookup.

```zig
/// The same mix on light: decode, mix, encode.
fn mixLight(a: u8, b: u8, k: u32, n: u32) u8 {
    const la: u32 = toLight(a);
    const lb: u32 = toLight(b);
    return toByte(@intCast((la * (n - k) + lb * k + n / 2) / n));
}
```

*Quoted from the source: `mixLight` from `snippets/09-graphics/linear-light.zig`.*

Compare `mixLight` with `mixBytes` in the snippet above. The arithmetic is
the same. Only the type of number in the arithmetic is different.

The [Alpha Blending](https://www.ziglang.in/learn/graphics/blending/) chapter blends the bytes
directly, and the chapter tells you this. To blend in linear light, do these
steps:

1. Decode both colours with `toLight`.
2. Do the same blend in 16 bits.
3. Encode the result with `toByte`.

## What linear light does not fix

Linear light describes how light adds, for example two torches that point at
one wall. Paint does not operate in this way, because pigments absorb light.

Yellow paint mixed with blue paint makes green. Yellow light mixed with blue
light makes grey, in linear light or in bytes.

Thus a linear mix is correct for a screen and for a camera. A linear mix is
not a model of paint.

## Explain before you read the answer

Draw a checkerboard of single black and white pixels. Look at the checkerboard
from the other side of the room, so that the squares become one blur. Which
grey looks the same: byte 128 or byte 188?

The answer is 188. Half of the pixels give full light, and half of the pixels
give no light. Your eye averages the light, thus your eye sees 50% light. 50%
light is byte 188, not 128.
