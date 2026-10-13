//! The native front end: the engine in a raylib window.
//!
//! This file does what `web/src/scripts/paint.ts` does in the browser, and
//! nothing more. It reads the mouse and the keyboard, calls the engine, and
//! copies the rectangle the engine says changed into a texture. Every
//! decision about pixels is the engine's.
//!
//!   zig build run                          open the window
//!   zig build native -Dtarget=x86_64-windows   a Windows .exe, from any OS

const std = @import("std");
const rl = @import("rl");
const engine = @import("engine");
const build_options = @import("build_options");

const width = engine.default_width;
const height = engine.default_height;
const bar = 28; // the status line under the picture

/// The same named brushes as the browser studio.
const Preset = struct { name: [:0]const u8, brush: engine.Brush };
const presets = [_]Preset{
    .{ .name = "Pencil", .brush = .{ .hardness = 0.9, .flow = 0.9, .spacing = 0.15, .follow = 0.6, .pressure = 0.6 } },
    .{ .name = "Ink", .brush = .{ .hardness = 0.95, .flow = 1, .spacing = 0.1, .follow = 0.35, .pressure = 1 } },
    .{ .name = "Soft", .brush = .{ .hardness = 0.1, .flow = 0.12, .spacing = 0.2, .follow = 0.5, .pressure = 0.3 } },
    .{ .name = "Airbrush", .brush = .{ .hardness = 0, .flow = 0.04, .spacing = 0.1, .follow = 0.8 } },
    .{ .name = "Calligraphy", .brush = .{ .hardness = 0.95, .flow = 1, .spacing = 0.08, .follow = 0.4, .pressure = 0.4, .aspect = 0.2, .angle = -45 } },
    .{ .name = "Ribbon", .brush = .{ .hardness = 0.8, .flow = 1, .spacing = 0.08, .follow = 0.4, .pressure = 0.5, .aspect = 0.25, .angle = 90, .follow_direction = true } },
    .{ .name = "Spray", .brush = .{ .hardness = 0.6, .flow = 0.7, .spacing = 1.2, .jitter = 0.6, .scatter = 2.5 } },
    .{ .name = "Dry brush", .brush = .{ .hardness = 0.8, .flow = 0.9, .spacing = 0.04, .follow = 0.5, .pressure = 0.4, .bristles = 9, .contact = 0.55 } },
};

const colors = [_][3]u8{
    .{ 0x26, 0x33, 0x4d }, .{ 200, 40, 40 },  .{ 230, 140, 20 }, .{ 240, 200, 50 },
    .{ 40, 150, 70 },      .{ 50, 110, 200 }, .{ 120, 60, 160 }, .{ 255, 255, 255 },
};

const Tool = enum { paint, erase, fill };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var doc: engine.Document = try .init(gpa, width, height, engine.default_layers, engine.default_history_budget);
    defer doc.deinit();

    const headless = build_options.frames != null;
    if (headless) {
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        // A smoke run draws the engine's demo picture, so CI checks a
        // window can show what the tests drew.
        try engine.demo.draw(&doc);
    }

    rl.InitWindow(width, height + bar, "Paint");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // The texture is the size of the document and starts as a copy of the
    // display. After that only changed rectangles are uploaded.
    _ = doc.render();
    const texture = rl.LoadTextureFromImage(.{
        .data = doc.display.ptr,
        .width = width,
        .height = height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    });
    defer rl.UnloadTexture(texture);

    // Room to copy one changed rectangle into, row by row: a texture update
    // needs the rectangle's pixels next to each other.
    const scratch = try gpa.alloc(engine.Rgba, width * height);
    defer gpa.free(scratch);

    var preset: usize = 0;
    var color: usize = 0;
    var size: f32 = 8;
    var tool: Tool = .paint;
    var seed: u32 = 1;
    var drawing = false;
    var frame: usize = 0;
    var message: [:0]const u8 = "";

    while (!rl.WindowShouldClose()) : (frame += 1) {
        if (build_options.frames) |n| if (frame >= n) break;

        // ---- keyboard --------------------------------------------------------
        const ctrl = rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL);
        if (!drawing) {
            if (ctrl and rl.IsKeyPressed(rl.KEY_Z)) _ = doc.undo();
            if (ctrl and rl.IsKeyPressed(rl.KEY_Y)) _ = doc.redo();
            if (ctrl and rl.IsKeyPressed(rl.KEY_S)) {
                message = if (save(init.io, &doc)) "Saved painting.png" else |_| "Saving failed";
            }
            if (!ctrl) {
                for (0..presets.len) |i| {
                    if (rl.IsKeyPressed(rl.KEY_ONE + @as(c_int, @intCast(i)))) preset = i;
                }
                if (rl.IsKeyPressed(rl.KEY_P)) tool = .paint;
                if (rl.IsKeyPressed(rl.KEY_E)) tool = .erase;
                if (rl.IsKeyPressed(rl.KEY_F)) tool = .fill;
                if (rl.IsKeyPressed(rl.KEY_C)) color = (color + 1) % colors.len;
                if (rl.IsKeyPressed(rl.KEY_LEFT_BRACKET)) size = @max(1, size - 2);
                if (rl.IsKeyPressed(rl.KEY_RIGHT_BRACKET)) size = @min(80, size + 2);
                if (rl.IsKeyPressed(rl.KEY_L)) _ = doc.setActiveLayer(1 - doc.active_layer);
            }
        }

        // ---- mouse -------------------------------------------------------------
        // A mouse has no pressure, and the browser reports 0.5 for one, so
        // the native build does the same and both draw alike.
        const m = rl.GetMousePosition();
        const p: engine.Point = .{ .x = m.x, .y = m.y, .pressure = 0.5 };
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and m.y < height) {
            switch (tool) {
                .fill => _ = doc.fillAt(@intFromFloat(@max(m.x, 0)), @intFromFloat(@max(m.y, 0)), colors[color]) catch false,
                .paint, .erase => {
                    var brush = presets[preset].brush;
                    brush.radius = size;
                    brush.color = colors[color];
                    brush.seed = seed;
                    doc.beginStroke(brush, if (tool == .erase) .eraser else .brush, p);
                    drawing = true;
                },
            }
        } else if (drawing and rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            doc.moveStroke(p);
        } else if (drawing) {
            doc.endStroke();
            drawing = false;
            seed += 1;
        }
        if (drawing and !rl.IsWindowFocused()) {
            // Focus lost halfway through: drop the stroke, as the browser does.
            doc.cancelStroke();
            drawing = false;
        }

        // ---- picture -----------------------------------------------------------
        const r = doc.render();
        if (!r.isEmpty()) {
            var i: usize = 0;
            var y = r.y0;
            while (y < r.y1) : (y += 1) {
                const row = @as(usize, y) * width;
                @memcpy(scratch[i..][0..r.width()], doc.display[row + r.x0 .. row + r.x1]);
                i += r.width();
            }
            rl.UpdateTextureRec(texture, .{
                .x = @floatFromInt(r.x0),
                .y = @floatFromInt(r.y0),
                .width = @floatFromInt(r.width()),
                .height = @floatFromInt(r.height()),
            }, scratch.ptr);
        }

        rl.BeginDrawing();
        rl.ClearBackground(.{ .r = 40, .g = 42, .b = 54, .a = 255 });
        rl.DrawTexture(texture, 0, 0, rl.WHITE);
        var status_buf: [160]u8 = undefined;
        const status = std.mem.printSentinel(&status_buf, "{s}  {s}  size {d}  {s} layer   1-8 brush  P/E/F  [ ]  C colour  L layer  Ctrl+Z/Y  Ctrl+S   {s}", .{
            presets[preset].name,
            @tagName(tool),
            @as(u32, @intFromFloat(size)),
            if (doc.active_layer == 0) "bottom" else "top",
            message,
        }, 0) catch "";
        const c = colors[color];
        rl.DrawRectangle(6, height + 6, 16, 16, .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 });
        rl.DrawText(status.ptr, 28, height + 8, 12, .{ .r = 220, .g = 222, .b = 230, .a = 255 });
        rl.EndDrawing();
    }

    if (build_options.screenshot) |path| {
        // raylib wants a C string, ending in a zero byte.
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        rl.TakeScreenshot((try std.mem.printSentinel(&path_buf, "{s}", .{path}, 0)).ptr);
    }
}

fn save(io: std.Io, doc: *engine.Document) !void {
    const file = try std.Io.Dir.cwd().createFile(io, "painting.png", .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try doc.writePng(&writer.interface);
    try writer.interface.flush();
}
