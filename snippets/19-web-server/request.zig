//! title: Parsing an HTTP Request
//! A request line, some headers, a blank line. The blank line is the hard part.

const std = @import("std");

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    version: []const u8,
    /// Slices into the original bytes; nothing is copied.
    headers: [][2][]const u8,
    body: []const u8,

    /// Header names are case-insensitive, which is not a detail you can skip:
    /// curl sends `Host`, some proxies send `HOST`, and a client written by
    /// hand sends `host`. Comparing them exactly works until it does not.
    pub fn header(r: Request, name: []const u8) ?[]const u8 {
        for (r.headers) |pair| {
            if (std.ascii.eqlIgnoreCase(pair[0], name)) return pair[1];
        }
        return null;
    }
};

pub const Error = error{ Malformed, TooManyHeaders };

pub fn parse(bytes: []const u8, storage: [][2][]const u8) Error!Request {
    // The header section ends at the first blank line. Everything after it is
    // body, and finding that boundary is the whole framing problem: HTTP has
    // no length up front, so the parser reads until it sees CRLF CRLF.
    const split = std.mem.find(u8, bytes, "\r\n\r\n") orelse return error.Malformed;
    const head = bytes[0..split];
    const body = bytes[split + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");

    const request_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (parts.next() != null) return error.Malformed;

    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.Malformed;
        if (count == storage.len) return error.TooManyHeaders;
        storage[count] = .{
            line[0..colon],
            // Optional whitespace after the colon, and only after it. A space
            // before the colon is malformed, and treating it as acceptable is
            // how request smuggling gets started.
            std.mem.trimStart(u8, line[colon + 1 ..], " \t"),
        };
        count += 1;
    }

    return .{
        .method = method,
        .target = target,
        .version = version,
        .headers = storage[0..count],
        .body = body,
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const raw =
        "POST /submit?id=7 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "content-type: application/x-www-form-urlencoded\r\n" ++
        "Content-Length: 13\r\n" ++
        "\r\n" ++
        "name=ada&ok=1";

    var storage: [16][2][]const u8 = undefined;
    const request = try parse(raw, &storage);

    try out.print("method  {s}\n", .{request.method});
    try out.print("target  {s}\n", .{request.target});
    try out.print("version {s}\n\n", .{request.version});

    for (request.headers) |pair| try out.print("  {s}: {s}\n", .{ pair[0], pair[1] });

    // Asked for with a different case than it was sent with.
    try out.print("\nlookup \"Content-Type\" -> {s}\n", .{request.header("Content-Type").?});
    try out.print("lookup \"Missing\"      -> {s}\n\n", .{
        if (request.header("Missing") == null) "absent" else "present",
    });

    try out.print("body ({d} bytes) {s}\n", .{ request.body.len, request.body });
    const declared = request.header("content-length").?;
    try out.print("Content-Length says {s}, and it agrees: {}\n\n", .{
        declared,
        request.body.len == try std.fmt.parseInt(usize, declared, 10),
    });

    for ([_][]const u8{
        "GET /only-one-line\r\n\r\n",
        "GET /extra parts HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nBadHeader\r\n\r\n",
        "GET / HTTP/1.1\r\n",
    }) |bad| {
        if (parse(bad, &storage)) |_| {
            try out.writeAll("accepted, which is wrong\n");
        } else |err| {
            try out.print("rejected: {t}\n", .{err});
        }
    }

    try out.flush();
}
