//! title: File Uploads
//! A format where the client picks the delimiter, and the filename is a lie until proven otherwise.

const std = @import("std");

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
};

pub const Error = error{ NoBoundary, Malformed, TooManyParts };

/// `multipart/form-data; boundary=----abc123`. The client chooses the
/// boundary and announces it here, which is the opposite of every other format
/// in this section: the delimiter is data, not a constant.
pub fn boundaryOf(content_type: []const u8) Error![]const u8 {
    const at = std.mem.find(u8, content_type, "boundary=") orelse return error.NoBoundary;
    const rest = content_type[at + "boundary=".len ..];
    const end = std.mem.findScalar(u8, rest, ';') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " \"");
    if (value.len == 0) return error.NoBoundary;
    return value;
}

/// Everything after the last slash or backslash, and never `..`.
///
/// The filename comes from the client and is the single most dangerous string
/// in an upload handler. Joining it to a directory without this is a write
/// anywhere the process can write, which is worse than the read the
/// [path chapter](/learn/web-server/static/) was about.
pub fn safeFilename(raw: []const u8) ?[]const u8 {
    var name = raw;
    if (std.mem.findScalarLast(u8, name, '/')) |i| name = name[i + 1 ..];
    // Backslash too: a Windows client sends `C:\Users\me\photo.png`, and a
    // parser that only strips `/` keeps the whole thing as one filename.
    if (std.mem.findScalarLast(u8, name, '\\')) |i| name = name[i + 1 ..];
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    if (std.mem.findScalar(u8, name, 0) != null) return null;
    return name;
}

fn attribute(header: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, header, key) orelse return null;
    const rest = header[at + key.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.findScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

pub fn parse(body: []const u8, boundary: []const u8, out: []Part, scratch: []u8) Error![]Part {
    // The delimiter is CRLF + "--" + boundary. The CRLF belongs to the
    // delimiter, not to the data before it, and a parser that forgets this
    // appends two bytes to every uploaded file. It is invisible in a text
    // field and corrupts an image.
    const delim = std.mem.print(scratch, "\r\n--{s}", .{boundary}) catch return error.Malformed;

    // The first boundary has no leading CRLF, so the body is normalised by
    // pretending one was there.
    var cursor: usize = if (std.mem.startsWith(u8, body, delim[2..])) delim.len - 2 else return error.Malformed;

    var n: usize = 0;
    while (true) {
        if (std.mem.startsWith(u8, body[cursor..], "--")) break; // closing delimiter
        if (!std.mem.startsWith(u8, body[cursor..], "\r\n")) return error.Malformed;
        cursor += 2;

        const head_end = std.mem.findPos(u8, body, cursor, "\r\n\r\n") orelse return error.Malformed;
        const head = body[cursor..head_end];
        const data_start = head_end + 4;

        const next = std.mem.findPos(u8, body, data_start, delim) orelse return error.Malformed;

        var disposition: []const u8 = "";
        var content_type: ?[]const u8 = null;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:")) disposition = line;
            if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                content_type = std.mem.trim(u8, line["content-type:".len..], " ");
            }
        }

        if (n == out.len) return error.TooManyParts;
        out[n] = .{
            .name = attribute(disposition, "name=") orelse return error.Malformed,
            .filename = attribute(disposition, "filename="),
            .content_type = content_type,
            .data = body[data_start..next],
        };
        n += 1;
        cursor = next + delim.len;
    }
    return out[0..n];
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const content_type = "multipart/form-data; boundary=----zig42";
    const boundary = try boundaryOf(content_type);
    try out.print("boundary announced by the client: {s}\n\n", .{boundary});

    const body =
        "------zig42\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "My holiday\r\n" ++
        "------zig42\r\n" ++
        "Content-Disposition: form-data; name=\"photo\"; filename=\"../../etc/passwd\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "PNG\r\ndata\r\n" ++
        "------zig42--\r\n";

    var parts: [8]Part = undefined;
    var scratch: [64]u8 = undefined;
    const parsed = try parse(body, boundary, &parts, &scratch);

    try out.print("{d} parts\n\n", .{parsed.len});
    for (parsed) |part| {
        try out.print("name         {s}\n", .{part.name});
        try out.print("filename     {s}\n", .{part.filename orelse "(none, so it is a field)"});
        if (part.filename) |raw| {
            try out.print("  as sent    {s}\n", .{raw});
            try out.print("  safe form  {s}\n", .{safeFilename(raw) orelse "(refused)"});
        }
        try out.print("content-type {s}\n", .{part.content_type orelse "(unset)"});
        try out.print("data         {d} bytes: \"{s}\"\n\n", .{ part.data.len, part.data });
    }

    // The data of the second part ends at "data", not at "data\r\n". Those two
    // bytes belong to the delimiter.
    try out.print("the photo is {d} bytes, and \"PNG\\r\\ndata\" is {d}\n\n", .{
        parsed[1].data.len,
        "PNG\r\ndata".len,
    });

    try out.writeAll("filenames a client might send\n");
    for ([_][]const u8{
        "holiday.png",
        "../../etc/passwd",
        "C:\\Users\\me\\photo.png",
        "..",
        "",
    }) |raw| {
        try out.print("  {s: <24} -> {s}\n", .{ raw, safeFilename(raw) orelse "(refused)" });
    }

    try out.flush();
}
