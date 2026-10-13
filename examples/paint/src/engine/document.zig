//! The picture: its layers, the stroke being drawn, its history, and what the
//! screen should show.
//!
//! Nothing here reads input, opens a window or looks at a clock. The front end
//! calls `beginStroke`, `moveStroke` and `endStroke` with points, and copies
//! out what `render` says changed. That is the whole interface, which is why
//! the same engine runs in a browser, in a native window, and in tests that
//! have neither.

const std = @import("std");
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const pixel = @import("pixel.zig");
const Rgba = pixel.Rgba;
const Brush = @import("brush.zig").Brush;
const Stroke = @import("stroke.zig").Stroke;
const Dab = @import("stroke.zig").Dab;
const Mask = @import("mask.zig").Mask;
const History = @import("history.zig").History;
const fill = @import("fill.zig");
const png = @import("png.zig");

/// A brush and an eraser are one stroke engine with two ways of finishing.
/// One enum rather than two flags, so "fill and erase at the same time" is a
/// state the program cannot be in.
pub const Tool = enum { brush, eraser };

const Active = struct {
    stroke: Stroke,
    tool: Tool,
    layer: u32,
    /// The brush's opacity on the 0 to 65535 scale, fixed for the stroke.
    opacity: u32,
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Bottom first. Each one is `width * height` premultiplied pixels.
    layers: [][]Rgba,
    visible: []bool,
    active_layer: u32 = 0,
    /// Coverage of the stroke in progress.
    mask: Mask,
    /// What the screen shows: every visible layer over white paper, with the
    /// stroke in progress applied. Always opaque.
    display: []Rgba,
    /// The part of `display` that is out of date.
    stale: Rect = .empty,
    history: History,
    stroke: ?Active = null,
    /// False after an action whose undo could not be kept. A front end can
    /// say so instead of letting Undo silently skip it.
    history_ok: bool = true,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, layer_count: u32, history_budget: usize) !Document {
        const count = @as(usize, width) * height;

        const layers = try gpa.alloc([]Rgba, layer_count);
        errdefer gpa.free(layers);
        var made: usize = 0;
        errdefer for (layers[0..made]) |l| gpa.free(l);
        for (layers) |*l| {
            l.* = try gpa.alloc(Rgba, count);
            @memset(l.*, .transparent);
            made += 1;
        }

        const visible = try gpa.alloc(bool, layer_count);
        errdefer gpa.free(visible);
        @memset(visible, true);

        var mask: Mask = try .init(gpa, width, height);
        errdefer mask.deinit(gpa);

        const display = try gpa.alloc(Rgba, count);
        @memset(display, .white);

        return .{
            .gpa = gpa,
            .width = width,
            .height = height,
            .layers = layers,
            .visible = visible,
            .mask = mask,
            .display = display,
            .stale = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height },
            .history = .init(history_budget),
        };
    }

    pub fn deinit(d: *Document) void {
        d.history.deinit(d.gpa);
        d.gpa.free(d.display);
        d.mask.deinit(d.gpa);
        d.gpa.free(d.visible);
        for (d.layers) |l| d.gpa.free(l);
        d.gpa.free(d.layers);
    }

    // ---- strokes ----------------------------------------------------------

    /// The sink `Stroke` sends its dabs to. Each dab goes into the stroke
    /// buffer, and the screen is marked stale where it landed.
    ///
    /// It carries its own copy of the brush rather than reading the one in
    /// `doc.stroke`, because `Stroke.begin` places the first dab before the
    /// stroke it returns has been stored anywhere.
    const Painter = struct {
        doc: *Document,
        brush: Brush,

        pub fn dab(p: Painter, d: Dab) void {
            p.doc.mask.stamp(d, p.brush.hardness, p.brush.aspect, p.brush.flow);
            p.doc.stale = p.doc.stale.join(Rect.around(d.x, d.y, d.radius, p.doc.width, p.doc.height));
        }
    };

    /// Start a stroke. The brush is copied, so changing a slider halfway
    /// through a stroke cannot change the stroke. A stroke already in progress
    /// is cancelled first.
    pub fn beginStroke(d: *Document, brush: Brush, tool: Tool, p: Point) void {
        if (d.stroke != null) d.cancelStroke();
        const b = brush.sanitized();
        const stroke = Stroke.begin(b, p, Painter{ .doc = d, .brush = b });
        d.stroke = .{
            .stroke = stroke,
            .tool = tool,
            .layer = d.active_layer,
            .opacity = @intFromFloat(@round(b.opacity * 65535.0)),
        };
    }

    pub fn moveStroke(d: *Document, p: Point) void {
        if (d.stroke == null) return;
        const s = &d.stroke.?.stroke;
        s.move(p, Painter{ .doc = d, .brush = s.brush });
    }

    /// Put the stroke onto its layer, once, and keep the old pixels for undo.
    pub fn endStroke(d: *Document) void {
        const active = d.stroke orelse return;
        const r = d.mask.dirty;
        const layer = d.layers[active.layer];

        d.history_ok = d.history.record(d.gpa, active.layer, layer, d.width, r);

        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                const i = @as(usize, y) * d.width + x;
                layer[i] = applyStroke(active, layer[i], d.mask.coverage[i]);
            }
        }
        d.mask.clear();
        d.stroke = null;
        d.stale = d.stale.join(r);
    }

    /// Drop the stroke in progress without changing any layer. Used when the
    /// pointer is lost halfway through a stroke.
    pub fn cancelStroke(d: *Document) void {
        if (d.stroke == null) return;
        d.stale = d.stale.join(d.mask.dirty);
        d.mask.clear();
        d.stroke = null;
    }

    /// One pixel of a layer with the stroke applied. The preview on screen
    /// and the commit both call this, so what you see while drawing is
    /// exactly what you get when you let go.
    fn applyStroke(active: Active, below: Rgba, coverage: u16) Rgba {
        const amount = (@as(u32, coverage) * active.opacity + 32767) / 65535;
        return switch (active.tool) {
            .brush => pixel.paint(below, active.stroke.brush.color, amount),
            .eraser => pixel.erase(below, amount),
        };
    }

    // ---- other actions ----------------------------------------------------

    /// Fill the area around (`x`, `y`) on the active layer with an opaque
    /// colour. Returns false if there was nothing to change.
    pub fn fillAt(d: *Document, x: u32, y: u32, color: [3]u8) !bool {
        if (d.stroke != null or x >= d.width or y >= d.height) return false;
        const layer = d.layers[d.active_layer];
        const new: Rgba = .opaqueRgb(color);
        // Filling a region with the colour it already has would find the
        // whole region and change nothing.
        if (std.meta.eql(layer[@as(usize, y) * d.width + x], new)) return false;

        var region = try fill.find(d.gpa, layer, d.width, d.height, x, y);
        defer region.deinit(d.gpa);

        d.history_ok = d.history.record(d.gpa, d.active_layer, layer, d.width, region.bounds);
        var it = region.inside.iterator(.{});
        while (it.next()) |i| layer[i] = new;
        d.stale = d.stale.join(region.bounds);
        return true;
    }

    pub fn undo(d: *Document) bool {
        if (d.stroke != null) return false;
        const e = d.history.undo(d.layers, d.width) orelse return false;
        d.stale = d.stale.join(e.rect);
        return true;
    }

    pub fn redo(d: *Document) bool {
        if (d.stroke != null) return false;
        const e = d.history.redo(d.layers, d.width) orelse return false;
        d.stale = d.stale.join(e.rect);
        return true;
    }

    /// Choose the layer the next action draws on. Refused during a stroke.
    pub fn setActiveLayer(d: *Document, index: u32) bool {
        if (d.stroke != null or index >= d.layers.len) return false;
        d.active_layer = index;
        return true;
    }

    pub fn setVisible(d: *Document, index: u32, visible: bool) void {
        if (index >= d.layers.len) return;
        d.visible[index] = visible;
        d.stale = .{ .x0 = 0, .y0 = 0, .x1 = d.width, .y1 = d.height };
    }

    // ---- output -----------------------------------------------------------

    /// Bring `display` up to date and return the rectangle that changed, so a
    /// front end copies only that part to the screen.
    pub fn render(d: *Document) Rect {
        const r = d.stale;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                d.display[@as(usize, y) * d.width + x] = d.composite(x, y);
            }
        }
        d.stale = .empty;
        return r;
    }

    /// One screen pixel: white paper, then each visible layer from the
    /// bottom up.
    fn composite(d: *const Document, x: u32, y: u32) Rgba {
        const i = @as(usize, y) * d.width + x;
        var out: Rgba = .white;
        for (d.layers, d.visible, 0..) |layer, visible, li| {
            if (!visible) continue;
            var p = layer[i];
            if (d.stroke) |active| {
                if (active.layer == li) p = applyStroke(active, p, d.mask.coverage[i]);
            }
            out = pixel.over(p, out);
        }
        return out;
    }

    /// FNV-1a over the R, G and B bytes of the display, the same hash the
    /// guide's picture checks use. Call `render` first.
    pub fn displayHash(d: *const Document) u32 {
        var h = std.hash.Fnv1a_32.init();
        for (d.display) |p| h.update(&.{ p.r, p.g, p.b });
        return h.final();
    }

    /// The picture as a PNG, flattened onto white paper.
    pub fn writePng(d: *Document, out: *std.Io.Writer) !void {
        d.stale = .{ .x0 = 0, .y0 = 0, .x1 = d.width, .y1 = d.height };
        _ = d.render();
        try png.write(d.gpa, out, d.display, d.width, d.height);
    }
};

const testing = std.testing;

fn newDoc() !Document {
    return Document.init(testing.allocator, 64, 48, 2, 1 << 20);
}

test "a stroke shows while drawing, and looks the same after it is committed" {
    var d = try newDoc();
    defer d.deinit();
    _ = d.render();
    const blank = d.displayHash();

    d.beginStroke(.{ .radius = 6, .color = .{ 200, 30, 30 } }, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 50, .y = 30 });
    _ = d.render();
    const preview = d.displayHash();
    try testing.expect(preview != blank);

    d.endStroke();
    _ = d.render();
    try testing.expectEqual(preview, d.displayHash());
}

test "opacity 0 leaves the layer unchanged" {
    var d = try newDoc();
    defer d.deinit();
    d.beginStroke(.{ .opacity = 0 }, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 50, .y = 30 });
    d.endStroke();
    for (d.layers[0]) |p| try testing.expectEqual(Rgba.transparent, p);
}

test "a stroke crossing itself does not get darker" {
    var d = try newDoc();
    defer d.deinit();
    // Half opacity, full flow: the stroke itself becomes fully covered, and
    // the opacity is applied once on top.
    const brush: Brush = .{ .radius = 4, .flow = 1, .opacity = 0.5, .color = .{ 0, 0, 0 } };
    d.beginStroke(brush, .brush, .{ .x = 5, .y = 20 });
    d.moveStroke(.{ .x = 60, .y = 20 });
    d.moveStroke(.{ .x = 5, .y = 20 }); // back over the same line
    d.endStroke();
    try testing.expectEqual(@as(u8, 128), d.layers[0][20 * 64 + 30].a);
}

test "cancelling a stroke leaves no ghost" {
    var d = try newDoc();
    defer d.deinit();
    _ = d.render();
    const blank = d.displayHash();
    d.beginStroke(.{}, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 40, .y = 40 });
    d.cancelStroke();
    _ = d.render();
    try testing.expectEqual(blank, d.displayHash());
    try testing.expect(!d.history.canUndo());
}

test "undo and redo a stroke and a fill" {
    var d = try newDoc();
    defer d.deinit();
    _ = d.render();
    const blank = d.displayHash();

    d.beginStroke(.{ .radius = 3 }, .brush, .{ .x = 0, .y = 24 });
    d.moveStroke(.{ .x = 63, .y = 24 });
    d.endStroke();
    _ = d.render();
    const stroked = d.displayHash();

    try testing.expect(try d.fillAt(5, 5, .{ 255, 220, 0 }));
    _ = d.render();
    const filled = d.displayHash();

    try testing.expect(d.undo());
    _ = d.render();
    try testing.expectEqual(stroked, d.displayHash());
    try testing.expect(d.undo());
    _ = d.render();
    try testing.expectEqual(blank, d.displayHash());
    try testing.expect(!d.undo());

    try testing.expect(d.redo());
    try testing.expect(d.redo());
    _ = d.render();
    try testing.expectEqual(filled, d.displayHash());
}

test "the line divides the fill: only the top half turns yellow" {
    var d = try newDoc();
    defer d.deinit();
    d.beginStroke(.{ .radius = 3, .hardness = 1, .flow = 1 }, .brush, .{ .x = -10, .y = 24 });
    d.moveStroke(.{ .x = 80, .y = 24 });
    d.endStroke();
    _ = try d.fillAt(5, 5, .{ 255, 220, 0 });
    try testing.expectEqual(@as(u8, 220), d.layers[0][5 * 64 + 5].g);
    try testing.expectEqual(Rgba.transparent, d.layers[0][40 * 64 + 5]);
}

test "the eraser reveals the layer below, white paint covers it" {
    var d = try newDoc();
    defer d.deinit();
    const red: [3]u8 = .{ 220, 0, 0 };
    // Bottom layer: solid red everywhere.
    _ = try d.fillAt(0, 0, red);
    // Top layer: solid blue everywhere.
    _ = d.setActiveLayer(1);
    _ = try d.fillAt(0, 0, .{ 0, 0, 220 });

    const hard: Brush = .{ .radius = 5, .hardness = 1, .flow = 1, .color = .{ 255, 255, 255 } };
    d.beginStroke(hard, .eraser, .{ .x = 16, .y = 24 });
    d.endStroke();
    d.beginStroke(hard, .brush, .{ .x = 48, .y = 24 });
    d.endStroke();
    _ = d.render();

    try testing.expectEqual(Rgba.opaqueRgb(red), d.display[24 * 64 + 16]); // erased: red shows
    try testing.expectEqual(Rgba.white, d.display[24 * 64 + 48]); // white paint
}

test "a hidden layer is not drawn" {
    var d = try newDoc();
    defer d.deinit();
    _ = try d.fillAt(0, 0, .{ 0, 0, 0 });
    d.setVisible(0, false);
    _ = d.render();
    try testing.expectEqual(Rgba.white, d.display[0]);
}

test "the exported PNG holds the screen's pixels" {
    var d = try newDoc();
    defer d.deinit();
    d.beginStroke(.{ .radius = 8, .color = .{ 10, 120, 200 } }, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 50, .y = 40 });
    d.endStroke();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try d.writePng(&out.writer);
    try testing.expect(std.mem.startsWith(u8, out.written(), "\x89PNG"));
}
