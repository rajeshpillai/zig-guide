//! title: Writing CSV
//! Quote a field only when it needs it, double the quotes inside, and prove
//! the writer by reading its output back.

const std = @import("std");
const csv = @import("csv-read.zig");

const Io = std.Io;

/// A field needs quotes if it contains a byte that means something to a
/// CSV reader: the separator, a quote, or a line break.
fn needsQuotes(field: []const u8) bool {
    return std.mem.findAny(u8, field, ",\"\r\n") != null;
}

fn writeField(w: *Io.Writer, field: []const u8) !void {
    if (!needsQuotes(field)) return w.writeAll(field);

    try w.writeByte('"');
    for (field) |b| {
        // A quote inside the field is written twice.
        if (b == '"') try w.writeByte('"');
        try w.writeByte(b);
    }
    try w.writeByte('"');
}

fn writeRecord(w: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try writeField(w, field);
    }
    // RFC 4180 ends each record with "\r\n", and spreadsheet programs expect
    // it. A reader that accepts "\n" also accepts "\r\n".
    try w.writeAll("\r\n");
}

/// The mistake this chapter exists to prevent: join the fields with commas.
fn writeRecordNaive(w: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(field);
    }
    try w.writeAll("\r\n");
}

const rows = [_][]const []const u8{
    &.{ "id", "name", "note" },
    &.{ "1", "Pencil", "" },
    &.{ "2", "Widget, large", "blue" },
    &.{ "3", "Lamp", "two\nlines" },
    &.{ "4", "Sign", "the \"best\" one" },
    &.{ "5", " padded ", "ends with a quote\"" },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Write the rows and show the bytes, with \r and \n made visible.
    try out.print("1. the file\n", .{});
    try save(io, dir, "out.csv", writeRecord);
    try showBytes(io, dir, "out.csv", out);

    // 2. Read the file back with the reader from the previous chapter, and
    //    compare every field with what we wrote.
    try out.print("2. round trip\n", .{});
    try roundTrip(io, gpa, dir, "out.csv", out);

    // 3. The same rows, joined with commas and nothing else.
    try out.print("3. naive join\n", .{});
    try save(io, dir, "naive.csv", writeRecordNaive);
    try showBytes(io, dir, "naive.csv", out);
    try roundTrip(io, gpa, dir, "naive.csv", out);

    try dir.deleteFile(io, "out.csv");
    try dir.deleteFile(io, "naive.csv");
}

fn save(io: Io, dir: Io.Dir, name: []const u8, comptime writeFn: anytype) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var fw = file.writer(io, &buf);
    for (rows) |row| try writeFn(&fw.interface, row);
    try fw.interface.flush();
}

fn roundTrip(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var fr = file.reader(io, &buf);
    var reader: csv.CsvReader = .{ .r = &fr.interface, .gpa = gpa };
    defer reader.deinit();

    var i: usize = 0;
    while (reader.next()) |maybe| : (i += 1) {
        const got = maybe orelse break;
        const want = if (i < rows.len) rows[i] else &[_][]const u8{};
        if (got.len != want.len) {
            try out.print("   record {d}: field count {d}, wrote {d}\n", .{ i, got.len, want.len });
            continue;
        }
        for (got, want, 0..) |g, w, f| {
            if (!std.mem.eql(u8, g, w)) {
                try out.print("   record {d} field {d}: read [{f}], wrote [{f}]\n", .{ i, f, visible(g), visible(w) });
            }
        }
    } else |err| {
        try out.print("   record {d}: {t} on line {d}\n", .{ i, err, reader.line });
        return;
    }
    try out.print("   read {d} records, wrote {d}\n", .{ i, rows.len });
}

/// Formats a field with its newlines shown as \n, so it stays on one line.
fn visible(field: []const u8) std.fmt.Alt([]const u8, writeVisible) {
    return .{ .data = field };
}

fn writeVisible(field: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    for (field) |b| if (b == '\n') try w.writeAll("\\n") else try w.writeByte(b);
}

fn showBytes(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    var buf: [512]u8 = undefined;
    const bytes = try dir.readFile(io, name, &buf);
    try out.writeAll("   ");
    for (bytes, 0..) |b, i| switch (b) {
        '\r' => try out.writeAll("\\r"),
        '\n' => try out.writeAll(if (i + 1 == bytes.len) "\\n\n" else "\\n\n   "),
        else => try out.writeByte(b),
    };
}
