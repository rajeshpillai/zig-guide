//! The browser front end's half in Zig: a set of exported functions the page
//! calls. It holds one document and the current brush, and does nothing the
//! engine does not already do. Pointer events, sliders and the canvas are the
//! page's job (web/src/scripts/paint.ts in the guide).
//!
//! Every function takes and returns plain numbers, because that is all a
//! WebAssembly call can carry. The picture itself is not passed at all: the
//! page reads `display` straight out of this module's memory.

const std = @import("std");
const engine = @import("engine");

const gpa = std.heap.wasm_allocator;

var doc: ?engine.Document = null;
var brush: engine.Brush = .{};
var tool: engine.Tool = .brush;
var changed: engine.Rect = .empty;
var png_bytes: []u8 = &.{};

/// Open a new, empty document. Returns false if there was not enough memory.
export fn paint_init(width: u32, height: u32) bool {
    if (doc) |*d| d.deinit();
    doc = engine.Document.init(gpa, width, height, engine.default_layers, engine.default_history_budget) catch {
        doc = null;
        return false;
    };
    return true;
}

/// Where the display pixels start in memory: `width * height` RGBA values.
export fn paint_display() [*]engine.Rgba {
    return doc.?.display.ptr;
}

/// Set every brush setting at once. Values out of range are fixed by the
/// engine, so the page can pass slider values straight through.
export fn paint_set_brush(
    radius: f32,
    hardness: f32,
    flow: f32,
    opacity: f32,
    spacing: f32,
    follow: f32,
    pressure: f32,
    jitter: f32,
    scatter: f32,
    aspect: f32,
    angle: f32,
    follow_direction: bool,
    r: u8,
    g: u8,
    b: u8,
    seed: u32,
    contact: f32,
    bristles: u32,
) void {
    brush = .{
        .radius = radius,
        .hardness = hardness,
        .flow = flow,
        .opacity = opacity,
        .spacing = spacing,
        .follow = follow,
        .pressure = pressure,
        .jitter = jitter,
        .scatter = scatter,
        .aspect = aspect,
        .angle = angle,
        .follow_direction = follow_direction,
        .color = .{ r, g, b },
        .seed = seed,
        .contact = contact,
        .bristles = bristles,
    };
}

/// 0 is the brush, 1 the eraser.
export fn paint_set_tool(t: u32) void {
    tool = if (t == 1) .eraser else .brush;
}

export fn paint_begin(x: f32, y: f32, pressure: f32) void {
    doc.?.beginStroke(brush, tool, .{ .x = x, .y = y, .pressure = pressure });
}

export fn paint_move(x: f32, y: f32, pressure: f32) void {
    doc.?.moveStroke(.{ .x = x, .y = y, .pressure = pressure });
}

export fn paint_end() void {
    doc.?.endStroke();
}

export fn paint_cancel() void {
    doc.?.cancelStroke();
}

export fn paint_fill(x: u32, y: u32) bool {
    return doc.?.fillAt(x, y, brush.color) catch false;
}

export fn paint_undo() bool {
    return doc.?.undo();
}

export fn paint_redo() bool {
    return doc.?.redo();
}

export fn paint_can_undo() bool {
    return doc.?.history.canUndo();
}

export fn paint_can_redo() bool {
    return doc.?.history.canRedo();
}

/// False after an action whose undo could not be kept.
export fn paint_history_ok() bool {
    return doc.?.history_ok;
}

export fn paint_set_layer(index: u32) bool {
    return doc.?.setActiveLayer(index);
}

export fn paint_set_visible(index: u32, visible: bool) void {
    doc.?.setVisible(index, visible);
}

/// Bring the display up to date. Returns false if nothing changed; otherwise
/// the changed rectangle is read with `paint_changed`.
export fn paint_render() bool {
    changed = doc.?.render();
    return !changed.isEmpty();
}

/// One edge of the last changed rectangle: 0 = x0, 1 = y0, 2 = x1, 3 = y1.
export fn paint_changed(edge: u32) u32 {
    return switch (edge) {
        0 => changed.x0,
        1 => changed.y0,
        2 => changed.x1,
        else => changed.y1,
    };
}

export fn paint_hash() u32 {
    return doc.?.displayHash();
}

/// Encode the picture as a PNG. Returns its length, or 0 on failure; the bytes
/// are at `paint_png` until the next call.
export fn paint_export_png() u32 {
    gpa.free(png_bytes);
    png_bytes = &.{};
    var out: std.Io.Writer.Allocating = .init(gpa);
    doc.?.writePng(&out.writer) catch {
        out.deinit();
        return 0;
    };
    png_bytes = out.toOwnedSlice() catch {
        out.deinit();
        return 0;
    };
    return @intCast(png_bytes.len);
}

export fn paint_png() [*]u8 {
    return png_bytes.ptr;
}

/// Draw the demo picture on a separate document and compare its hash with the
/// one the native tests pinned. True means this build draws exactly what the
/// native build draws.
export fn paint_self_test() bool {
    var d = engine.Document.init(gpa, engine.default_width, engine.default_height, engine.default_layers, engine.default_history_budget) catch return false;
    defer d.deinit();
    engine.demo.draw(&d) catch return false;
    return d.displayHash() == engine.demo.hash;
}
