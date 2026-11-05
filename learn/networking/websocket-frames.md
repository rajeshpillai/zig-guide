# WebSocket Frames

> The two header bytes as packed structs, the three length forms, the client mask, and the frames that std.http.Server refuses.

After the [handshake](https://www.ziglang.in/learn/networking/websocket-handshake/), the
connection carries frames. A frame is a length-prefixed message, as in
[Three Ways to Frame](https://www.ziglang.in/learn/networking/framing/), with a header of two to
fourteen bytes. The header tells the receiver four things:

- the type of the frame: text, binary, ping, pong or close
- if the frame is the last part of a message
- the length of the payload
- if the sender masked the payload, and with which mask

The program writes frames with std, decodes a header, masks a client frame
by hand, and gives eight frames to the reader of `std.http.Server`.

```zig
const std = @import("std");
const WebSocket = std.http.Server.WebSocket;

fn printBytes(out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes, 0..) |b, i| {
        if (i > 0) try out.writeByte(' ');
        try out.print("{x:0>2}", .{b});
    }
}

/// A frame from a client. The server writes frames with std, but std has no
/// client, so this is the other half. RFC 6455 requires a client to mask
/// each frame, and a server must refuse a frame without the mask.
fn writeClientFrame(
    w: *std.Io.Writer,
    opcode: WebSocket.Opcode,
    fin: bool,
    mask: [4]u8,
    payload: []const u8,
) !void {
    try w.writeByte(@bitCast(WebSocket.Header0{ .opcode = opcode, .fin = fin }));
    if (payload.len <= 125) {
        try w.writeByte(@bitCast(WebSocket.Header1{
            .payload_len = @enumFromInt(payload.len),
            .mask = true,
        }));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len16, .mask = true }));
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len64, .mask = true }));
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    // The mask is four bytes. Each byte i of the payload gets an XOR with byte
    // i % 4 of the mask. The same XOR on the receiver gives the payload back.
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

/// Print the fields of a packed struct with the bits that each one uses.
fn printLayout(out: *std.Io.Writer, comptime T: type) !void {
    try out.print("  {s}:", .{@typeName(T)[std.mem.findScalarLast(u8, @typeName(T), '.').? + 1 ..]});
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const low = @bitOffsetOf(T, name);
        const high = low + @bitSizeOf(F) - 1;
        if (low == high) {
            try out.print(" {s}={d}", .{ name, low });
        } else {
            try out.print(" {s}={d}-{d}", .{ name, low, high });
        }
    }
    try out.print("\n", .{});
}

/// Give one frame to std, as a server reads it, and print the result.
fn serverReads(out: *std.Io.Writer, name: []const u8, frame: []const u8) !void {
    var in: std.Io.Reader = .fixed(frame);
    var unused: [0]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&unused);
    var ws: WebSocket = .{ .key = "", .input = &in, .output = &sink };
    try out.print("  {s:<26} -> ", .{name});
    if (ws.readSmallMessage()) |msg| {
        try out.print("{t} \"{s}\"\n", .{ msg.opcode, msg.data });
    } else |err| {
        try out.print("error.{t}\n", .{err});
    }
}

var big: [70000]u8 = @splat('x');

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // ------------------------------------------------ the three length forms

    // A server frame from std. The length field has 7 bits. The values 126
    // and 127 mean that a 16-bit or a 64-bit length follows.
    try out.print("server frames, header bytes:\n", .{});
    var frame_buf: [70016]u8 = undefined;
    for ([_]usize{ 5, 125, 126, 200, 70000 }) |len| {
        var w: std.Io.Writer = .fixed(&frame_buf);
        var ws: WebSocket = .{ .key = "", .input = undefined, .output = &w };
        try ws.writeMessage(big[0..len], .text);
        const header_len: usize = switch (frame_buf[1] & 0x7f) {
            126 => 4,
            127 => 10,
            else => 2,
        };
        try out.print("  {d:>5} bytes: ", .{len});
        try printBytes(out, frame_buf[0..header_len]);
        try out.print("\n", .{});
    }

    // ----------------------------------------------------- the header bits

    // The first two bytes are two packed structs in std. Zig packs the
    // first field into the lowest bits.
    try out.print("\nthe header structs in std, field=bits, bit 0 first:\n", .{});
    try printLayout(out, WebSocket.Header0);
    try printLayout(out, WebSocket.Header1);

    // A @bitCast reads the fields of one byte.
    try out.print("\nthe first two bytes, 81 85:\n", .{});
    const h0: WebSocket.Header0 = @bitCast(@as(u8, 0x81));
    const h1: WebSocket.Header1 = @bitCast(@as(u8, 0x85));
    try out.print("  byte 0 = {b:0>8}: fin={} rsv=0 opcode={t}\n", .{ @as(u8, 0x81), h0.fin, h0.opcode });
    try out.print("  byte 1 = {b:0>8}: mask={} length={d}\n", .{ @as(u8, 0x85), h1.mask, @intFromEnum(h1.payload_len) });

    // ------------------------------------------------------------ the mask

    // The example from section 5.7 of RFC 6455: "Hello", masked.
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var hello_buf: [16]u8 = undefined;
    var hello_w: std.Io.Writer = .fixed(&hello_buf);
    try writeClientFrame(&hello_w, .text, true, mask, "Hello");
    const hello = hello_w.buffered();

    try out.print("\nmask a client frame, mask ", .{});
    try printBytes(out, &mask);
    try out.print(":\n", .{});
    for ("Hello", 0..) |c, i| {
        try out.print("  {d}  '{c}' {x:0>2} ^ {x:0>2} = {x:0>2}\n", .{ i, c, c, mask[i % 4], c ^ mask[i % 4] });
    }
    try out.print("frame: ", .{});
    try printBytes(out, hello);
    const rfc = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try out.print("\nthe same as RFC 6455: {}\n", .{std.mem.eql(u8, hello, &rfc)});

    // ------------------------------------------------ what std.http accepts

    // Each frame goes to readSmallMessage, as a server reads it.
    try out.print("\nstd reads each frame:\n", .{});
    try serverReads(out, "masked text", hello);

    var f: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&f);
    try writeClientFrame(&w, .ping, true, mask, "are you there");
    try serverReads(out, "masked ping", w.buffered());

    w = .fixed(&f);
    try writeClientFrame(&w, .pong, true, mask, "");
    try writeClientFrame(&w, .text, true, mask, "after");
    try serverReads(out, "pong, then text", w.buffered());

    try serverReads(out, "unmasked text", &.{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' });

    w = .fixed(&f);
    try writeClientFrame(&w, .text, false, mask, "Hel");
    try writeClientFrame(&w, .continuation, true, mask, "lo");
    try serverReads(out, "\"Hel\" + \"lo\" in 2 frames", w.buffered());

    w = .fixed(&f);
    try writeClientFrame(&w, .continuation, true, mask, "lo");
    try serverReads(out, "continuation alone", w.buffered());

    // The length says 300 bytes. The reader has a buffer of 10 bytes.
    try serverReads(out, "300 bytes, 10-byte buffer", &.{ 0x81, 0xfe, 0x01, 0x2c, 1, 2, 3, 4, 5, 6 });

    w = .fixed(&f);
    try writeClientFrame(&w, .connection_close, true, mask, &.{ 0x03, 0xe8 });
    try serverReads(out, "close, code 1000", w.buffered());

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`11-networking.websocket-frames`)*

## Two bytes of header

The first byte holds the `fin` bit, three reserved bits and a 4-bit opcode.
The second byte holds the `mask` bit and a 7-bit length. std declares each
byte as a `packed struct(u8)`: `WebSocket.Header0` and `WebSocket.Header1`
in `std.http.Server`. The program reads the layout of the two structs with
`@bitOffsetOf` and prints it:

```
the header structs in std, field=bits, bit 0 first:
  Header0: opcode=0-3 rsv3=4 rsv2=5 rsv1=6 fin=7
  Header1: payload_len=0-6 mask=7
```

Zig puts the first field of a packed struct in the lowest bits. RFC 6455
draws the frame with the highest bit first. Thus the fields in std are in
the reverse order of the diagram in the RFC: `opcode` is the first field in
Zig, and the RFC draws it last in the byte.

A `@bitCast` turns a byte into the struct, and the program prints the
fields:

```
the first two bytes, 81 85:
  byte 0 = 10000001: fin=true rsv=0 opcode=text
  byte 1 = 10000101: mask=true length=5
```

*Figure: The bytes 81 and 85 as 16 bits, with each field of Header0 and Header1 marked in turn. The layout and the two bytes from the program above. Step through the fields from bit 7 to bit 0.*

## Three length forms

The length field has 7 bits, thus it holds 0 to 127. The values 0 to 125
are the length. The value 126 means that a 16-bit length follows. The value
127 means that a 64-bit length follows. Both are big-endian, as in
[Binary Protocols and Byte Order](https://www.ziglang.in/learn/networking/binary-protocols/).

```
server frames, header bytes:
      5 bytes: 81 05
    125 bytes: 81 7d
    126 bytes: 81 7e 00 7e
    200 bytes: 81 7e 00 c8
  70000 bytes: 81 7f 00 00 00 00 00 01 11 70
```

A message of 125 bytes has a header of two bytes. A message of 126 bytes
has a header of four bytes. The `payload_len` field in std is a
non-exhaustive enum. Thus a `switch` on the field has three cases: `.len16`,
`.len64`, and `else` for a length in the field itself.

## The mask

A client must mask each frame that it sends. The client selects four random
bytes, sends the bytes after the length, and XORs each payload byte with one
mask byte. Byte `i` uses mask byte `i % 4`. The receiver does the same XOR
and gets the payload back, because `x ^ m ^ m == x`.

```zig
/// A frame from a client. The server writes frames with std, but std has no
/// client, so this is the other half. RFC 6455 requires a client to mask
/// each frame, and a server must refuse a frame without the mask.
fn writeClientFrame(
    w: *std.Io.Writer,
    opcode: WebSocket.Opcode,
    fin: bool,
    mask: [4]u8,
    payload: []const u8,
) !void {
    try w.writeByte(@bitCast(WebSocket.Header0{ .opcode = opcode, .fin = fin }));
    if (payload.len <= 125) {
        try w.writeByte(@bitCast(WebSocket.Header1{
            .payload_len = @enumFromInt(payload.len),
            .mask = true,
        }));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len16, .mask = true }));
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(@bitCast(WebSocket.Header1{ .payload_len = .len64, .mask = true }));
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    // The mask is four bytes. Each byte i of the payload gets an XOR with byte
    // i % 4 of the mask. The same XOR on the receiver gives the payload back.
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}
```

*Quoted from the source: `writeClientFrame` from `snippets/11-networking/websocket-frames.zig`.*

The mask does not make the data secret. The mask is in the frame. The mask
protects proxies on the path. Without the mask, a script in a browser could
send bytes that look like an HTTP request to a proxy. The proxy could then
store a wrong answer in its cache. With a random mask, the script cannot control the
bytes on the wire.

The program masks "Hello" with the mask from section 5.7 of RFC 6455:

```
mask a client frame, mask 37 fa 21 3d:
  0  'H' 48 ^ 37 = 7f
  1  'e' 65 ^ fa = 9f
  2  'l' 6c ^ 21 = 4d
  3  'l' 6c ^ 3d = 51
  4  'o' 6f ^ 37 = 58
frame: 81 85 37 fa 21 3d 7f 9f 4d 51 58
the same as RFC 6455: true
```

*Figure: The payload "Hello", the four mask bytes repeated under it, and the XOR of each pair. The mask trace from the program above. The figure stops at byte 4 and asks you which mask byte it uses.*

The server does not mask its frames. The direction decides the rule:

- A frame from a client must have the mask. A server closes the connection
  if the frame has no mask.
- A frame from a server must not have the mask. A client closes the
  connection if the mask is present.

std has no client, thus `writeClientFrame` is in the program. The mask in
the program is a constant, so that CI can compare the output. A real client
selects a new random mask for each frame.
[A WebSocket Client](https://www.ziglang.in/learn/networking/websocket-client/) does that.

## What std reads, and what it refuses

`WebSocket.readSmallMessage` reads one frame, checks it, removes the mask,
and returns the opcode and the payload. The program gives it eight frames:

```
std reads each frame:
  masked text                -> text "Hello"
  masked ping                -> ping "are you there"
  pong, then text            -> text "after"
  unmasked text              -> error.MissingMaskBit
  "Hel" + "lo" in 2 frames   -> error.MessageOversize
  continuation alone         -> error.UnexpectedOpCode
  300 bytes, 10-byte buffer  -> error.MessageOversize
  close, code 1000           -> error.ConnectionClose
```

Each line shows one property of the reader in std:

- **A ping returns to your code.** std does not answer it. Send the pong
  with `writeMessage(data, .pong)`.
- **std skips a pong.** The reader reads the next frame and returns that
  frame.
- **std requires the mask**, as the RFC says for a server.
- **std refuses a message in fragments.** A frame without the `fin` bit gives
  `error.MessageOversize`, and a continuation frame gives
  `error.UnexpectedOpCode`. The RFC lets a sender split a message into
  frames, and a browser can do it. std reads only complete messages.
- **The whole frame must fit in the buffer of the reader.** std returns
  the payload as a slice of that buffer. Thus the size of the buffer is the
  largest message that the server accepts. The name `readSmallMessage` says
  this.
- **A close frame is an error value.** std stops after the first two bytes
  of the frame. Thus your code does not get the status code of the close
  frame. The rest of the frame stays unread in the stream. std does not send
  the close answer either.

These limits are the right size for the reason that std has this code. The
build system of Zig talks to its web interface (`zig build --webui`) over a
WebSocket, with small messages in both directions. For a server that
accepts messages from any browser, you must fill the gaps yourself.
[A WebSocket Server on a Socket](https://www.ziglang.in/learn/networking/websocket-server/) shows
how to answer a ping and a close.
