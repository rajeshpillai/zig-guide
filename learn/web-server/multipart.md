# File Uploads

> A format where the client selects the delimiter, and a filename that you cannot trust until you check it.

Each other format in this section has a delimiter that the specification
fixes. `&` separates query parameters, `;` separates cookies, and `\r\n\r\n`
ends the headers. You can write the delimiter into the parser.

`multipart/form-data` cannot do that. The bytes of a file can be any value,
and they can include any delimiter that you select. Thus the **client**
selects a string, checks that the data does not contain the string, and
announces the string:

```
Content-Type: multipart/form-data; boundary=----zig42
```

The parser reads the delimiter from a header, and then searches for the
delimiter. For this reason, the multipart parser is separate from the
urlencoded parser. It is not a variation of the urlencoded parser.

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

/// `multipart/form-data; boundary=----abc123`. The client selects the
/// boundary and announces it here. Each other format in this section uses a
/// fixed delimiter. Here the delimiter is data.
pub fn boundaryOf(content_type: []const u8) Error![]const u8 {
    const at = std.mem.find(u8, content_type, "boundary=") orelse return error.NoBoundary;
    const rest = content_type[at + "boundary=".len ..];
    const end = std.mem.findScalar(u8, rest, ';') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " \"");
    if (value.len == 0) return error.NoBoundary;
    return value;
}

/// All text after the last slash or backslash, and never `..`.
///
/// The filename comes from the client. In an upload handler, the filename is
/// a dangerous string. If code joins it to a directory without this function,
/// the client can write to any place where the process can write. That is
/// worse than the read in the [path chapter](https://www.ziglang.in/learn/web-server/static/).
pub fn safeFilename(raw: []const u8) ?[]const u8 {
    var name = raw;
    if (std.mem.findScalarLast(u8, name, '/')) |i| name = name[i + 1 ..];
    // Also remove backslashes. A Windows client sends `C:\Users\me\photo.png`.
    // A parser that removes only `/` keeps the full path as one filename.
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
    // The delimiter is CRLF + "--" + boundary. The CRLF is part of the
    // delimiter, not part of the data before it. If a parser forgets this, it
    // adds two bytes to each uploaded file. In a text field, you cannot see
    // the two bytes. In an image, they corrupt the data.
    const delim = std.mem.print(scratch, "\r\n--{s}", .{boundary}) catch return error.Malformed;

    // The first boundary has no CRLF before it. Thus the parser starts as if
    // the CRLF is there.
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
    // bytes are part of the delimiter.
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

## What the program did

**The body has two parts, and only one part is a file.** Both parts come in
the same way. The difference is a `filename` attribute in the
`Content-Disposition` header. If the attribute is present, the part is a file.
If the attribute is absent, the part is an ordinary field.

A form can contain
the two types together. Thus an upload handler is also a form handler.

**The photo is 9 bytes, not 11.** The data is `PNG\r\ndata`, and the body has
`\r\n` immediately before the next boundary line. Those two bytes are part of
the **delimiter**, not part of the file.

A parser that keeps the two bytes adds `\r\n` to each uploaded file. In a text
field, you will never see the difference. In a PNG, the two bytes corrupt the
last chunk. In a ZIP, they break the central directory. A checksum comparison
fails, and an examination of the file does not show the cause. The demo prints
the two numbers, thus you can check this yourself.

**The filename came as `../../etc/passwd`.** An attacker tries exactly this,
and the sanitised form is `passwd`. This is the same traversal as in the static
files chapter, but in the opposite direction. That chapter was about an
unauthorised **read**. This chapter is about an unauthorised **write**, to any
place where the process can write. The usual result is a web shell: a script
that the attacker puts into a directory that the server also serves.

**The sanitiser also removes backslashes.** A Windows client can legitimately
send `C:\Users\me\photo.png`. A parser that removes only `/` stores a file with
a path in its name. On a Unix server, that name is only ugly. If the name
reaches a Windows filesystem, the name is a traversal again.

**The safe filename is not the sent filename.** You can show the string from
the client as a name. You must not use the string as a name to open. The two
uses need different handling. When code mixes the two uses, `..` gets to the
filesystem.

## Limits of this parser

The parser needs the full body in memory. Real uploads are too large for that.
A program cannot keep a 2 GB file in a buffer before it parses the file. Thus a
production parser is a state machine, and reads give data to the state machine.
The parser sends out each part while the data streams through, and writes file
data directly to disk.

That design changes the code very much, but it changes none of the decisions
above:

- The client still selects the boundary.
- The last `\r\n` is still part of the delimiter.
- The filename is still untrusted.

One problem becomes more difficult. A boundary can come split across two reads.
Thus the matcher must keep partial state. Framing is the same problem for all
protocols.

## Check yourself

The client promises that the boundary is not in the data. What must a server
do if the boundary is in the data?

The answer: nothing special. If the boundary is inside a file, the parser
splits that file at exactly that point. The parser reads the data after that
point as the head of another part. Usually the result is a parse error, not two
files. Nothing tells you which result occurred, because there is no length to
compare. If the file data also contains a `Content-Disposition` line and a
blank line, you cannot see the split.

This is a real weakness of the design, and no validation fixes it. Long, random
boundaries make a collision unlikely. Browsers make a fixed prefix plus 16
random characters. Thus an accidental collision does not occur in practice. A
deliberate collision needs an attacker who already controls the boundary. That
attacker can already send all the parts that they want.

## If you know C

The search uses `memmem`, not `strstr`, because file data contains nul bytes.
Thus all C string functions are incorrect here. Suppose code calls `strlen` on
the contents of a part. Then `strlen` stops at the first nul byte, and the code
loses the rest of the file.

The other hazard in C is the filename. `basename()` is the obvious tool, and it
has two problems:

- The POSIX version can change its argument.
- No version rejects `..`, because `basename("..")` is `".."`.

Then `open(dir_fd, name)` with that name writes into the parent directory. The
sanitiser above rejects `..` explicitly. If the sanitiser returned a plausible
name for a dangerous input, it would hide the problem. When it returns nothing,
the caller must handle the problem.

## The end of this section

The section has eight chapters. Together, they make a small web server with
these parts:

- A request parser.
- A socket.
- Static files with a traversal guard.
- Routing.
- Urlencoded forms.
- Sessions.
- Templates.
- Uploads.

The parts that remain are mostly about scale, not about new ideas. [Many
clients](https://www.ziglang.in/learn/networking/many-clients/) shows the concurrency part.
