//! `zig build demo`: draw the demo picture and save it as demo.png, so a
//! change to the engine can be looked at, not only hashed.

const std = @import("std");
const engine = @import("engine");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var doc: engine.Document = try .init(gpa, engine.default_width, engine.default_height, engine.default_layers, engine.default_history_budget);
    defer doc.deinit();
    try engine.demo.draw(&doc);

    const file = try std.Io.Dir.cwd().createFile(init.io, "demo.png", .{});
    defer file.close(init.io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buf);
    try doc.writePng(&writer.interface);
    try writer.interface.flush();

    // The watercolour demo, scaled up eight times so a cell is visible.
    var wc: engine.Watercolor = try .init(gpa, 80, 50, 1);
    defer wc.deinit(gpa);
    engine.watercolor.demo(&wc);
    var cells: [80 * 50]engine.Rgba = undefined;
    const wc_hash = engine.watercolor.hash(wc, &cells);
    var big: engine.Document = try .init(gpa, 640, 400, 1, 0);
    defer big.deinit();
    for (0..400) |y| for (0..640) |x| {
        big.layers[0][y * 640 + x] = cells[(y / 8) * 80 + x / 8];
    };
    const wc_file = try std.Io.Dir.cwd().createFile(init.io, "watercolor.png", .{});
    defer wc_file.close(init.io);
    var wc_writer = wc_file.writer(init.io, &buf);
    try big.writePng(&wc_writer.interface);
    try wc_writer.interface.flush();

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try stdout.interface.print("wrote demo.png, display hash 0x{x:0>8}\n", .{doc.displayHash()});
    try stdout.interface.print("wrote watercolor.png, watercolour hash 0x{x:0>8}\n", .{wc_hash});
    try stdout.interface.flush();
}
