# Projects and Presets

> A project file keeps the layers that a PNG merges. A preset keeps a brush. Other people can write both, thus the program examines both first.

A PNG is for a completed picture that you share. It is a bad format for a picture that you will change again.

A PNG is flat. When the program saves a PNG, it merges the layers into one image. When you open the PNG again, nothing tells which paint was on which layer. Thus the eraser cannot show the bottom layer again. Two layers and the size of the page can make the picture again. One merged PNG cannot.

Thus the studio has two more types of file:

- **Save project** keeps each layer, and records which layers are visible.
- **Save brush** keeps the settings of a brush as a **preset**. A preset is a name and the numbers that control the brush. A preset holds no pixels.

## The project format

Before the code, the top of the file that implements the format describes it, field by field:

```
header, 16 bytes
  0  magic      4 bytes  "ZPNT"
  4  version    u16      1
  6  width      u32
 10  height     u32
 14  layers     u8       1 to 8
 15  active     u8       less than layers

each layer
  0  visible    u8       0 or 1
  1  size       u32      bytes of compressed pixels that follow
  5  pixels     size bytes, zlib: width * height premultiplied RGBA
```

The [Binary Files](https://www.ziglang.in/learn/files/binary-files/) chapter makes a format in the same way. The **magic** bytes tell the type of the file. The **version** tells which edition of the format the file uses. Thus a later program can change the format and still identify an old file.

The program compresses the pixels of each layer with zlib, the same compressor that the [PNG writer](https://www.ziglang.in/learn/graphics/png/) uses. An empty layer of 640 by 400 is 1,024,000 bytes of zeros. After compression, it is about one kilobyte.

```zig
pub fn save(gpa: std.mem.Allocator, doc: *const Document, out: *std.Io.Writer) !void {
    try out.writeAll(magic);
    try out.writeInt(u16, version, .little);
    try out.writeInt(u32, doc.width, .little);
    try out.writeInt(u32, doc.height, .little);
    try out.writeInt(u8, @intCast(doc.layers.len), .little);
    try out.writeInt(u8, @intCast(doc.active_layer), .little);

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);

    for (doc.layers, doc.visible) |layer, visible| {
        var packed_layer: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer packed_layer.deinit();
        compressor.* = try .init(&packed_layer.writer, window, .zlib, .default);
        try compressor.writer.writeAll(std.mem.sliceAsBytes(layer));
        try compressor.finish();

        try out.writeInt(u8, @intFromBool(visible), .little);
        try out.writeInt(u32, @intCast(packed_layer.written().len), .little);
        try out.writeAll(packed_layer.written());
    }
}
```

*Quoted from the source: `save` from `examples/paint/src/engine/project.zig`.*

## To open a file is to read bytes from an unknown source

To save is easy. The program wrote the data, and it trusts the data.

To open is different. The file can be from an older version. A failed download can cut it short, or a disk can damage it, or the file can be a different type. The program reads input from outside, thus it examines each field before it uses the field.

```zig
pub const OpenError = error{
    /// The first four bytes are not "ZPNT".
    NotAProject,
    /// A later version of this program wrote the file.
    NewerVersion,
    /// Width or height is 0 or larger than `max_side`.
    BadSize,
    /// No layers, too many, or an active layer that does not exist.
    BadLayers,
    /// The file ends before all of the data that it promised.
    Truncated,
    /// The compressed pixels do not decompress to exactly one layer.
    BadPixels,
    /// The colour of a pixel is larger than its alpha. A premultiplied pixel
    /// can never have such a value.
    NotPremultiplied,
    /// Bytes after the last layer.
    TrailingBytes,
    OutOfMemory,
};
```

*Quoted from the source: `OpenError` from `examples/paint/src/engine/project.zig`.*

Each type of problem in a file has its own error. The studio changes each error into a sentence that tells the person what to do. The picture on the screen does not change.

## Build the new document first

If an open fails, the work on the screen must not change.

Thus `open` makes a complete new document, separate from the open document. The studio swaps in the new document only if each layer decodes and each check passes. If something fails, `errdefer` frees the partial document. The open picture does not change.

```zig
/// Build a new document from a project file. If an error occurs, the
/// function returns no document and changes nothing.
pub fn open(gpa: std.mem.Allocator, bytes: []const u8, history_budget: usize) OpenError!Document {
    var in: Cursor = .{ .bytes = bytes };

    if (!std.mem.eql(u8, try in.take(4), magic)) return error.NotAProject;
    const file_version = try in.int(u16);
    if (file_version > version) return error.NewerVersion;
    if (file_version != version) return error.NotAProject;

    const width = try in.int(u32);
    const height = try in.int(u32);
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
    const layer_count = try in.int(u8);
    const active = try in.int(u8);
    if (layer_count == 0 or layer_count > max_layers or active >= layer_count) return error.BadLayers;

    // Read the layer table one time before any allocation. Eight layers of
    // 4096 by 4096 is 512 MB, and a 16-byte header can ask for that size. If
    // some layers are not in the file, or bytes follow the layers, the file
    // fails here at a low cost, before the large allocation.
    {
        var scan = in;
        for (0..layer_count) |_| {
            _ = try scan.int(u8);
            _ = try scan.take(try scan.int(u32));
        }
        if (scan.at != bytes.len) return error.TrailingBytes;
    }

    var doc: Document = try .init(gpa, width, height, layer_count, history_budget);
    errdefer doc.deinit();
    doc.active_layer = active;

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    for (doc.layers, doc.visible) |layer, *visible| {
        const flag = try in.int(u8);
        if (flag > 1) return error.BadLayers;
        visible.* = flag == 1;

        const size = try in.int(u32);
        const compressed = try in.take(size);

        // Decompress into the layer, then ask for one more byte. If a layer is
        // too short, the first read fails. If a layer is too long, a byte
        // remains for the second read.
        var reader: std.Io.Reader = .fixed(compressed);
        var inflate: flate.Decompress = .init(&reader, .zlib, window);
        inflate.reader.readSliceAll(std.mem.sliceAsBytes(layer)) catch return error.BadPixels;
        var extra: [1]u8 = undefined;
        if (inflate.reader.readSliceShort(&extra)) |n| {
            if (n != 0) return error.BadPixels;
        } else |_| return error.BadPixels;

        for (layer) |p| {
            if (p.r > p.a or p.g > p.a or p.b > p.a) return error.NotPremultiplied;
        }
    }

    doc.stale = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
    return doc;
}
```

*Quoted from the source: `open` from `examples/paint/src/engine/project.zig`.*

## A small file can ask for much memory

The header gives the size of the picture, and the program allocates the document from that size.

Eight layers of 4096 by 4096 pixels is 512 MB. A file that is only 16 bytes long can ask for that quantity, with no data after its header.

Thus, before it allocates anything, `open` reads the layer table one time:

- It reads the size of each layer and makes sure that the bytes are in the file.
- It makes sure that nothing follows the last layer.

If a file gives incorrect data about its contents, the file fails here, before the large allocation.

A test proves this with an allocator that refuses each request. If `open` asked for memory before the checks, the test would get `OutOfMemory` instead of `Truncated`.

## Checks inside the pixels

Two more checks examine the compressed pixels.

A layer must decompress to exactly `width × height × 4` bytes. `open` reads that number of bytes, and then asks for one more byte. If a layer is too short, the first read fails. If a layer is too long, a byte remains for the second read.

Each pixel must also be **premultiplied**, as the [Layers](https://www.ziglang.in/learn/paint/layers-and-the-eraser/) chapter explains. No colour channel can be larger than the alpha. The engine never writes a pixel that breaks this rule. Thus such a pixel means that the file is damaged, or that a different program wrote it.

## Brush presets

A preset is small, and a person can want to read or edit it. Thus presets are JSON:

```json
{
  "version": 1,
  "name": "Fine sketch",
  "brush": {
    "radius": 4,
    "flow": 0.7,
    "color": "#26334d"
  }
}
```

If the file does not have a field, the field gets the value of the default brush. The program skips fields that it does not know. Thus a preset from a later version still opens if its known fields are valid.

## 0.2, not 0.20000000298023224

The first preset from this code had `"aspect": 0.20000000298023224`.

The brush stores its settings as `f32`. `std.json` first changes an `f32` to an `f64`, and then writes it. The `f32` that is nearest to 0.2 is not exactly 0.2. After the change to `f64`, the difference is visible.

The file was correct, and it gave the same brush when the program read it. But a preset is for people to read and edit, and no person typed that number.

Thus `write` changes each setting into the shortest decimal that gives the same `f32` when the program reads it again. Zig's `{d}` format prints that decimal. `write` stores the decimal as an `f64`, and JSON then prints `0.2`:

```zig
/// The shortest decimal that gives `x` when a program reads it again, as
/// an `f64`. For the `f32` nearest to 0.2, the result is 0.2. A plain
/// change to `f64` gives 0.20000000298023224.
fn decimal(x: f32) f64 {
    var buf: [64]u8 = undefined;
    const text = std.mem.print(&buf, "{d}", .{x}) catch unreachable;
    return std.fmt.parseFloat(f64, text) catch unreachable;
}
```

*Quoted from the source: `decimal` from `examples/paint/src/engine/preset.zig`.*

When the program reads the file, it changes `0.2` back to an `f32` and gets the same bits that the brush had. The round-trip test examines this.

## Refuse, do not repair

The brush already has a function that moves each setting into its range: `sanitized`, in `brush.zig`. Each stroke sends its brush through this function. Thus a slider can never give the engine a value that it cannot draw with.

A preset file must not use `sanitized` to repair its values. A file with a radius of −3 is a damaged file. If the program silently changes −3 into 0.5, it hides the damage, and the person gets a brush that they did not make.

But `sanitized` is still useful here, as the definition of a valid brush. A brush is valid only when `sanitized` changes nothing:

```zig
/// Read a preset. The name in the result points into `name_buf`.
pub fn parse(gpa: std.mem.Allocator, json: []const u8, name_buf: *[max_name]u8) ParseError!Preset {
    const parsed = std.json.parseFromSlice(File, gpa, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAPreset,
    };
    defer parsed.deinit();
    const file = parsed.value;

    if (file.version > version) return error.NewerVersion;
    if (file.version != version) return error.NotAPreset;

    if (file.name.len == 0 or file.name.len > max_name) return error.BadName;
    for (file.name) |c| if (c < 0x20 or c == 0x7f) return error.BadName;

    const s = file.brush;
    const brush: Brush = .{
        .radius = @floatCast(s.radius),
        .hardness = @floatCast(s.hardness),
        .flow = @floatCast(s.flow),
        .opacity = @floatCast(s.opacity),
        .spacing = @floatCast(s.spacing),
        .follow = @floatCast(s.follow),
        .pressure = @floatCast(s.pressure),
        .jitter = @floatCast(s.jitter),
        .scatter = @floatCast(s.scatter),
        .aspect = @floatCast(s.aspect),
        .angle = @floatCast(s.angle),
        .follow_direction = s.follow_direction,
        .contact = @floatCast(s.contact),
        .bristles = s.bristles,
        .pickup = @floatCast(s.pickup),
        .drain = @floatCast(s.drain),
        .color = try parseColor(s.color),
    };
    // Valid means that the engine can draw with the brush without a change.
    // If `sanitized` must move a value, the value is out of range. NaN is
    // never equal to itself, thus a NaN also fails here.
    if (!std.meta.eql(brush.sanitized(), brush)) return error.OutOfRange;

    @memcpy(name_buf[0..file.name.len], file.name);
    return .{ .name = name_buf[0..file.name.len], .brush = brush };
}
```

*Quoted from the source: `parse` from `examples/paint/src/engine/preset.zig`.*

NaN is never equal to itself, thus a NaN setting fails the same comparison. The code does not repeat a list of ranges. Thus the preset check and the sliders cannot disagree.

## The cost of JSON

The browser build was 49 KB before the file features. After them, it is 146 KB.

To find where the 97 KB went, remove one function at a time and build again:

| part | adds |
|---|---|
| read a preset with `std.json` | 67 KB |
| open a project (zlib decompression) | 15 KB |
| write presets and projects, and the remainder | 15 KB |

`std.json` is general. It can parse any JSON into any Zig type. That is why `parseFromSlice(File, ...)` is one line. Most of the cost comes from that general design. A parser written by hand for only this one shape would be smaller. But it would be a second part of the code that must stay correct.

The page loads the engine only when you push Start. Thus only people who use the studio pay the cost, one time. For a program that loads on each page, it would be better to write the small parser.

## Checks

This test makes sure that a saved project opens with the same layers, visibility and active layer:

```zig
test "a saved project opens with the same layers, visibility and active layer" {
    const gpa = testing.allocator;
    var doc: Document = try .init(gpa, 48, 32, 2, 1 << 20);
    defer doc.deinit();
    doc.beginStroke(.{ .radius = 6, .color = .{ 200, 40, 40 } }, .brush, .{ .x = 4, .y = 4 });
    doc.moveStroke(.{ .x = 44, .y = 28 });
    doc.endStroke();
    _ = doc.setActiveLayer(1);
    _ = try doc.fillAt(40, 2, .{ 30, 90, 200 });
    doc.setVisible(0, false);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try save(gpa, &doc, &out.writer);

    var back = try open(gpa, out.written(), 1 << 20);
    defer back.deinit();
    try testing.expectEqual(doc.width, back.width);
    try testing.expectEqual(@as(u32, 1), back.active_layer);
    try testing.expectEqualSlices(bool, doc.visible, back.visible);
    for (doc.layers, back.layers) |a, b| try testing.expectEqualSlices(Rgba, a, b);
}
```

*Quoted from the source: `a saved project opens with the same layers, visibility and active layer` from `examples/paint/src/engine/project.zig`.*

This test makes sure that each type of damage gives its own error:

```zig
test "each kind of damage is rejected with its own error" {
    const gpa = testing.allocator;
    const good = try sample(gpa);
    defer gpa.free(good);
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);

    const Case = struct { offset: usize, value: u8, want: OpenError };
    const cases = [_]Case{
        .{ .offset = 0, .value = 'X', .want = error.NotAProject },
        .{ .offset = 4, .value = 2, .want = error.NewerVersion },
        .{ .offset = 6, .value = 0, .want = error.BadSize }, // width 48 -> 0
        .{ .offset = 14, .value = 9, .want = error.BadLayers }, // 9 layers
        .{ .offset = 15, .value = 2, .want = error.BadLayers }, // active 2 of 2
        .{ .offset = 16, .value = 7, .want = error.BadLayers }, // visible = 7
    };
    for (cases) |c| {
        @memcpy(bad, good);
        bad[c.offset] = c.value;
        try testing.expectError(c.want, open(gpa, bad, 1 << 20));
    }
    try testing.expectError(error.Truncated, open(gpa, good[0 .. good.len - 1], 1 << 20));

    const longer = try std.mem.concat(gpa, u8, &.{ good, "!" });
    defer gpa.free(longer);
    try testing.expectError(error.TrailingBytes, open(gpa, longer, 1 << 20));
}
```

*Quoted from the source: `each kind of damage is rejected with its own error` from `examples/paint/src/engine/project.zig`.*

This test cuts the file at each possible length, and changes each byte, one after the other:

- A cut file must never open.
- A file with a changed byte can still open, if the decompressed pixels are valid. But nothing can crash.
- If something leaks, the testing allocator makes the test fail.

```zig
test "every truncation and every flipped byte is rejected or opens cleanly, and nothing leaks" {
    const gpa = testing.allocator;
    const good = try sample(gpa);
    defer gpa.free(good);

    // Cut the file at each length.
    for (0..good.len) |n| {
        if (open(gpa, good[0..n], 1 << 20)) |doc| {
            var d = doc;
            d.deinit();
            return error.TestUnexpectedResult; // a cut file must never open
        } else |_| {}
    }

    // Flip each byte, one after the other. Some flips change compressed data
    // that still decodes to valid premultiplied pixels. Thus a file with a
    // flip can open. It must never crash, and the testing allocator makes
    // sure that it never leaks.
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    for (0..good.len) |i| {
        @memcpy(bad, good);
        bad[i] ^= 0xff;
        if (open(gpa, bad, 1 << 20)) |doc| {
            var d = doc;
            d.deinit();
        } else |_| {}
    }
}
```

*Quoted from the source: `every truncation and every flipped byte is rejected or opens cleanly, and nothing leaks` from `examples/paint/src/engine/project.zig`.*

This test uses the 512 MB header:

```zig
test "a header asking for 512 MB with no data behind it allocates nothing" {
    var header: [16]u8 = undefined;
    @memcpy(header[0..4], magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u32, header[6..10], max_side, .little);
    std.mem.writeInt(u32, header[10..14], max_side, .little);
    header[14] = max_layers;
    header[15] = 0;
    // An allocator that refuses each request. If `open` tried an allocation
    // before its checks, this test would get OutOfMemory instead.
    var none: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.Truncated, open(none.allocator(), &header, 0));
}
```

*Quoted from the source: `a header asking for 512 MB with no data behind it allocates nothing` from `examples/paint/src/engine/project.zig`.*

There is also a **fuzz test**. `zig build test --fuzz` runs it with inputs that the fuzzer makes and changes. The fuzzer searches for a byte sequence that crashes `open`. An ordinary test run gives the fuzz test only the valid file that it starts from.

This test makes sure that presets contain the numbers that a person types:

```zig
test "settings are written as typed: 0.2, not 0.20000000298023224" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, "Nib", .{ .aspect = 0.2, .hardness = 0.95 });
    try testing.expect(std.mem.find(u8, out.written(), "\"aspect\": 0.2,") != null);
    try testing.expect(std.mem.find(u8, out.written(), "\"hardness\": 0.95,") != null);
}
```

*Quoted from the source: `settings are written as typed: 0.2, not 0.20000000298023224` from `examples/paint/src/engine/preset.zig`.*

This test refuses presets for each reason:

```zig
test "a bad preset is refused with a reason, never repaired" {
    const Case = struct { json: []const u8, want: ParseError };
    const cases = [_]Case{
        .{ .json = "not json", .want = error.NotAPreset },
        .{ .json = "{\"version\":2,\"name\":\"x\",\"brush\":{}}", .want = error.NewerVersion },
        .{ .json = "{\"version\":1,\"name\":\"\",\"brush\":{}}", .want = error.BadName },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"color\":\"red\"}}", .want = error.BadColor },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"radius\":-3}}", .want = error.OutOfRange },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"flow\":7}}", .want = error.OutOfRange },
        .{ .json = "{\"version\":1,\"name\":\"x\",\"brush\":{\"bristles\":99}}", .want = error.OutOfRange },
    };
    var name: [max_name]u8 = undefined;
    for (cases) |c| try testing.expectError(c.want, parse(testing.allocator, c.json, &name));
}
```

*Quoted from the source: `a bad preset is refused with a reason, never repaired` from `examples/paint/src/engine/preset.zig`.*

## Explain before you read the answer

You get a project file from version 2 of this program. Version 2 added a field to the header.

Must version 1 try to open the file, and skip the field that it does not know?

No, it must not. Version 1 cannot know the position or the length of the new field. Thus it cannot know where the layers start. It refuses the file with `NewerVersion`, which tells the person exactly what to do: update the program. A preset is different. JSON gives a name to each field, thus the program can safely skip an unknown field.
