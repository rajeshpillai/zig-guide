# Rasterize Triangles

> Edge functions tell inside from outside, and the same three numbers interpolate values across the face.

The triangle is the primitive that a GPU actually draws. All other shapes
become triangles before they arrive at the rasterizer. A quad that you draw also
becomes triangles. Three vertices are always coplanar and always convex. For
this reason, the inside test is fast enough to run for each pixel.

The test is one function, and the rasterizer calls it three times:

```zig
fn edge(a: Point, b: Point, p: Point) i32 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}
```

The function calculates the 2D cross product of `b - a` and `p - a`. The
result is two times the signed area of the triangle `(a, b, p)`.

- The **sign** of the result tells you on which side of the line `ab` the
  point `p` is.
- The **magnitude** of the result is exactly the barycentric weight that
  interpolation needs.

Thus a rasterizer calculates the value one time and uses it two times.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const Point = struct { x: i32, y: i32 };

/// Two times the signed area of triangle (a, b, p). The value is positive on
/// one side of the line ab, negative on the other side, and zero on the line.
/// The sign alone is the inside test. The magnitude is the barycentric weight.
fn edge(a: Point, b: Point, p: Point) i32 {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

fn fillTriangle(a: Point, b: Point, c: Point, ca: u32, cb: u32, cc: u32) void {
    // Make the winding the same for all triangles. Then "inside" is always
    // the side where the values are zero or more. Without this step, a
    // triangle with the other winding disappears.
    var v0 = a;
    var v1 = b;
    const v2 = c;
    var col0 = ca;
    var col1 = cb;
    const col2 = cc;
    const area = edge(v0, v1, v2);
    if (area < 0) {
        std.mem.swap(Point, &v0, &v1);
        std.mem.swap(u32, &col0, &col1);
    }
    const total = edge(v0, v1, v2);
    if (total == 0) return; // degenerate: three collinear points make no face

    const min_x = @min(v0.x, @min(v1.x, v2.x));
    const max_x = @max(v0.x, @max(v1.x, v2.x));
    const min_y = @min(v0.y, @min(v1.y, v2.y));
    const max_y = @max(v0.y, @max(v1.y, v2.y));

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const p = Point{ .x = x, .y = y };
            const w0 = edge(v1, v2, p);
            const w1 = edge(v2, v0, p);
            const w2 = edge(v0, v1, p);
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            // The three edge values, divided by the total, are the barycentric
            // coordinates. Their sum is 1. Each coordinate is the weight for
            // the colour of one vertex: the nearer the pixel, the larger the
            // weight.
            const g0 = canvas.channels(col0);
            const g1 = canvas.channels(col1);
            const g2 = canvas.channels(col2);
            canvas.putPixel(&pixels, x, y, canvas.rgb(
                mix(w0, w1, w2, g0.r, g1.r, g2.r, total),
                mix(w0, w1, w2, g0.g, g1.g, g2.g, total),
                mix(w0, w1, w2, g0.b, g1.b, g2.b, total),
            ));
        }
    }
}

fn mix(w0: i32, w1: i32, w2: i32, c0: u8, c1: u8, c2: u8, total: i32) u8 {
    const sum = w0 * @as(i32, c0) + w1 * @as(i32, c1) + w2 * @as(i32, c2);
    return @intCast(@divTrunc(sum, total));
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 30));

    // Gouraud shading in three lines: one colour for each vertex, and the
    // colours interpolate across the face.
    fillTriangle(
        .{ .x = 4, .y = 28 },
        .{ .x = 30, .y = 2 },
        .{ .x = 40, .y = 26 },
        canvas.rgb(30, 30, 60),
        canvas.rgb(255, 255, 255),
        canvas.rgb(120, 120, 160),
    );

    // This triangle has the other winding and one flat colour. The triangle
    // still appears, because fillTriangle makes the winding the same.
    fillTriangle(
        .{ .x = 62, .y = 4 },
        .{ .x = 44, .y = 20 },
        .{ .x = 62, .y = 30 },
        canvas.rgb(255, 200, 60),
        canvas.rgb(255, 200, 60),
        canvas.rgb(255, 200, 60),
    );

    try canvas.dump(out, &pixels);
    try canvas.writePicture(init.io, out, "triangle.ppm", &pixels);

    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 10, .y = 0 };
    try out.print("\nedge value below the line ab: {d}\n", .{edge(a, b, .{ .x = 5, .y = 4 })});
    try out.print("edge value on the line ab:    {d}\n", .{edge(a, b, .{ .x = 5, .y = 0 })});
    try out.print("edge value above the line ab: {d}\n", .{edge(a, b, .{ .x = 5, .y = -4 })});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.triangle`)*

## Inside is three signs

A point is inside the triangle when all three edge functions have the same
sign. The snippet first makes the winding the same for all triangles. Then
"the same sign" means "all values are zero or more", and the second case is
not necessary:

```zig
if (edge(v0, v1, v2) < 0) {
    std.mem.swap(Point, &v0, &v1);
    std.mem.swap(u32, &col0, &col1);
}
```

If you swap two vertices, also swap their colours. If you do not, the shading
shows a mirror image on the triangles that have the other winding. When this
code gets more attributes, it is easy to forget to keep each vertex with its
attributes.

A production pipeline usually does not change the winding. It rejects one
winding on purpose. This method is *backface culling*. With backface culling,
a renderer quickly discards the far side of a closed mesh before it touches a
pixel.

## Barycentric coordinates at no extra cost

Divide the three edge values by their total. The result is three weights, and
the sum of the weights is one. Each weight measures how near the pixel is to
the vertex opposite that edge.

Multiply a value at each vertex by these weights. Then the value interpolates
linearly across the face:

```zig
const sum = w0 * c0 + w1 * c1 + w2 * c2;
return @intCast(@divTrunc(sum, total));
```

The snippet uses colour as the example. Press Run, and the picture under the
output shows the colours. The left triangle is Gouraud shading in three
lines.

The same three weights also interpolate texture coordinates, normals and
depth. This is the main reason that edge functions replaced scanline methods.
The inside test and the interpolation of attributes use the same arithmetic.

For a perspective projection, do the interpolation in `1/w` space. If you do
not, the textures warp visibly along the diagonal of a quad. This correction
is the origin of the name "perspective-correct" interpolation.

## Shared edges, and the top-left rule

Two triangles that share an edge have a problem. Think of a pixel whose
centre is exactly on the shared edge. For both triangles, the edge value of
that pixel is zero:

- With `>= 0`, the rasterizer draws the pixel two times.
- With `> 0`, the rasterizer leaves a gap.

When the code uses blending, a pixel drawn two times is visible. A gap is
always visible.

The solution is a rule that decides the tie only from the edge. The rule does
not look at the triangle that the code draws. For a top edge or a left edge,
zero counts as inside. For other edges, zero does not count as inside.

This rule is the **top-left rule**, and all hardware rasterizers use it. This
snippet does not use the rule, because it draws no shared edges. But code
that joins triangles into a mesh needs the rule.

## Why an incremental loop is faster

`edge` is affine in `p`. Thus a step of one pixel to the right adds a
constant, and a step of one row down adds a different constant.

A production rasterizer calculates the three edge values one time, at the
corner of the bounding box. Then it adds the constants for each pixel. This
method removes all multiplies from the inner loop.

After that change, the values for four or eight pixels fit in a SIMD
register. Then the rasterizer tests the full group of pixels at the same
time.

The version on this page is easy to read. The change to the fast version is
mechanical.

## Exercises

1. **Backface culling.** When the winding is negative, return early instead
   of a swap. Then draw the faces of a cube, and see the back faces
   disappear.
2. **Two triangles that share an edge.** Blend them at 50%, and look for the
   bright seam. Then add the top-left rule, and see the seam disappear.
3. **A depth buffer.** Interpolate a `z` value at each vertex with the same
   weights. Keep a second array with the nearest `z` for each pixel. Reject
   each pixel that is behind that `z`. This method replaces the painter's
   algorithm, and it works correctly for geometry that intersects.
