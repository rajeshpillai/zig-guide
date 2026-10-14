//! The paint engine. It reads no input, opens no window and has no clock:
//! points go in, pixels come out. Every front end (the browser, the native
//! window, the tests) is a thin layer over `Document`.

pub const Document = @import("engine/document.zig").Document;
pub const Tool = @import("engine/document.zig").Tool;
pub const Brush = @import("engine/brush.zig").Brush;
pub const Point = @import("engine/geometry.zig").Point;
pub const Rect = @import("engine/geometry.zig").Rect;
pub const Rgba = @import("engine/pixel.zig").Rgba;
pub const demo = @import("engine/demo.zig");
pub const Watercolor = @import("engine/watercolor.zig").Watercolor;
pub const watercolor = @import("engine/watercolor.zig");
pub const project = @import("engine/project.zig");
pub const preset = @import("engine/preset.zig");

/// The document size every front end opens with. The same 640 by 400 the
/// JavaScript course uses, so its memory arithmetic carries over: one layer
/// is 640 * 400 * 4 = 1,024,000 bytes.
pub const default_width = 640;
pub const default_height = 400;
pub const default_layers = 2;
/// Enough for about sixteen full-layer undo steps, and far more small ones.
pub const default_history_budget = 16 * 1024 * 1024;

test {
    _ = @import("engine/random.zig");
    _ = @import("engine/geometry.zig");
    _ = @import("engine/brush.zig");
    _ = @import("engine/stroke.zig");
    _ = @import("engine/mask.zig");
    _ = @import("engine/pixel.zig");
    _ = @import("engine/history.zig");
    _ = @import("engine/fill.zig");
    _ = @import("engine/png.zig");
    _ = @import("engine/document.zig");
    _ = @import("engine/demo.zig");
    _ = @import("engine/paper.zig");
    _ = @import("engine/watercolor.zig");
    _ = @import("engine/project.zig");
    _ = @import("engine/preset.zig");
}
