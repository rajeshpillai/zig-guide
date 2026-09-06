# File Uploads

> A format where the client picks the delimiter, and the filename is a lie until proven otherwise.

Every other format in this section has a delimiter fixed by the specification.
`&` separates query parameters, `;` separates cookies, `\r\n\r\n` ends the
headers. You can write the delimiter into the parser.

`multipart/form-data` cannot, and the reason is the whole shape of the format.
A file's bytes can be anything, including any delimiter you might have chosen.
So the **client** picks a string it has checked does not appear in the data,
and announces it:

```
Content-Type: multipart/form-data; boundary=----zig42
```

The parser reads the delimiter out of a header and then goes looking for it.
That single inversion is why this parser exists separately from the urlencoded
one, rather than being a variation on it.

## The program

```zig
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
/// [path chapter](https://www.ziglang.in/learn/web-server/static/) was about.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.multipart`)*

## What just happened

**Two parts, and only one is a file.** Both arrive the same way. What
distinguishes them is a `filename` attribute in the `Content-Disposition`
header: present means file, absent means ordinary field. A form can mix them
freely, which is why an upload handler is also a form handler.

**The photo is 9 bytes, not 11.** This is the detail worth slowing down for.
The data is `PNG\r\ndata`, and the body has `\r\n` immediately before the next
boundary line. Those two bytes belong to the **delimiter**, not to the file.

A parser that takes them anyway appends `\r\n` to every uploaded file. In a
text field you will never notice. In a PNG it corrupts the last chunk, in a
ZIP it breaks the central directory, and in a checksum comparison it fails for
reasons nobody can see by looking. The demo prints both numbers so the claim
is checkable rather than asserted.

**The filename arrived as `../../etc/passwd`.** Exactly what you would expect
somebody to try, and the sanitised form is `passwd`. This is the same
traversal as the static files chapter, with the stakes inverted. That one was
an unauthorised **read**. This is an unauthorised
**write**, anywhere the process can write. A web shell dropped into a directory
the server also serves is the classic outcome.

**Backslashes are stripped too.** `C:\Users\me\photo.png` is what a Windows
client legitimately sends, and a parser that only strips `/` stores a file
whose name contains a path. On a Unix server that is merely ugly; if the name
ever crosses back to a Windows filesystem it is a traversal again.

**The safe filename is not the sent filename.** Treating the client's string as
a name to display is fine. Treating it as a name to open is the bug. The two
uses want different handling, and conflating them is how `..` gets to the
filesystem.

## What this parser does not handle

It requires the whole body in memory. Real uploads are the case where that
stops being acceptable. A 2 GB file cannot be buffered before parsing, so a
production parser is a state machine fed by reads, emitting each part as it
streams past and writing file data straight to disk.

That changes the code substantially and none of the decisions above. The
boundary is still client-chosen, the trailing `\r\n` still belongs to the
delimiter, and the filename is still untrusted. What gets harder is that a
boundary can arrive split across two reads, so the matcher has to carry
partial state. That is the same problem framing covers for protocols
generally.

## Check yourself

The client promises the boundary does not appear in the data. What should a
server do if it does anyway?

Nothing special, and that is worth understanding. If the boundary appears
inside a file, the parser splits that file in two at exactly that point. Both
halves are valid parts as far as the format is concerned. There is no way to
detect it, because there is no length anywhere to check against.

That is a real weakness of the design, and it is mitigated by boundaries being
long and random rather than by any validation. Browsers generate a fixed
prefix plus 16 random characters. That makes an accidental collision
impossible in practice, and a deliberate one requires the attacker to already
control the boundary, at which point they can simply send whatever parts they
like anyway.

## If you have written C

The searching is `memmem` rather than `strstr`, and the reason is the whole
point: file data contains nul bytes, so every string function is wrong here.
Anything reaching for `strlen` on a part's contents has already lost the file.

The other C-shaped hazard is the filename. `basename()` is the obvious tool
and it has two traps: the POSIX version may modify its argument, and neither
version rejects `..`, since `basename("..")` is `".."`. Then `open(dir_fd,
name)` with that is a write into the parent directory. The sanitiser above
refuses it explicitly, because a function that returns something plausible for
a dangerous input is worse than one that returns nothing.

## Where this section ends

Eight chapters, and a small web server: a request parser, a socket, static
files with a traversal guard, routing, urlencoded forms, sessions, templates,
and uploads. What remains is scale rather than concept, and [many
clients](https://www.ziglang.in/learn/networking/many-clients/) covers the concurrency part.
