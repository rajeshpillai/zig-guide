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

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try stdout.interface.print("wrote demo.png, display hash 0x{x:0>8}\n", .{doc.displayHash()});
    try stdout.interface.flush();
}
