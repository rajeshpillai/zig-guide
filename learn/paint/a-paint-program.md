# A Paint Program You Can Test

> A paint program that you can use on this page, and the one rule that lets tests check each brush.

Press Start painting and draw.

*Interactive: the paint program, compiled to WebAssembly. Select a brush, a size and a colour. Draw on the bottom or the top layer, erase, fill, undo, and save a PNG. It runs on the web page of this chapter.*

You can use a mouse or a finger. If your pen has pressure, the line is thicker when you push harder.

Try the Calligraphy brush. Lines in one direction are thin, and lines across them are wide.

Draw on the bottom layer. Then select the top layer, draw again, and erase there. Where you erase, you see the bottom layer.

## One rule

The program has two parts:

- The **engine** calculates the value of each pixel. The engine is about 2,100 lines of Zig, and about 1,050 more lines of tests.
- The **front end** changes mouse and pen events into calls to the engine. Then it copies the pixels from the engine to the canvas.

The rule is that the engine never sees a mouse, a window or a clock. Points go in, and pixels come out.

The main type of the engine is a document. A document holds the layers, the current stroke, the history, and the data for the screen:

```zig
pub const Document = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Bottom first. Each one is `width * height` premultiplied pixels.
    layers: [][]Rgba,
    visible: []bool,
    active_layer: u32 = 0,
    /// The coverage of the current stroke.
    mask: Mask,
    /// The grain below the full picture, for brushes with less than full
    /// contact. The document makes it one time, thus each stroke touches the
    /// same hills.
    paper: Paper,
    /// The picture on the screen: each visible layer over white paper, with
    /// the current stroke applied. Always opaque.
    display: []Rgba,
    /// The part of `display` that is out of date.
    stale: Rect = .empty,
    history: History,
    stroke: ?Active = null,
    /// False after an action if the history could not keep its undo step. A
    /// front end can tell the user. Otherwise, Undo silently skips that action.
    history_ok: bool = true,

    // ...
};
```

*Quoted from the source: `Document` (fields only) from `examples/paint/src/engine/document.zig`.*

A front end calls a small number of methods on the document. A stroke is one `beginStroke` call, some `moveStroke` calls, and one `endStroke` call. Each call takes a point: an `x`, a `y` and a pressure.

After these calls, `render` updates `display` and returns the rectangle that changed. The front end copies that rectangle to the screen. The front end does nothing more.

## What the rule gives you

The engine needs no window. Thus a test can draw.

A test can start a stroke, move it, end it, and then examine the pixels. This test makes sure that a stroke looks the same while you draw it and after you release the pointer:

```zig
test "a stroke shows while drawing, and looks the same after it is committed" {
    var d = try newDoc();
    defer d.deinit();
    _ = d.render();
    const blank = d.displayHash();

    d.beginStroke(.{ .radius = 6, .color = .{ 200, 30, 30 } }, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 50, .y = 30 });
    _ = d.render();
    const preview = d.displayHash();
    try testing.expect(preview != blank);

    d.endStroke();
    _ = d.render();
    try testing.expectEqual(preview, d.displayHash());
}
```

*Quoted from the source: `a stroke shows while drawing, and looks the same after it is committed` from `examples/paint/src/engine/document.zig`.*

There are 80 tests of this type, and no test opens a window.

## The same pixels in all builds

The engine runs in three places: in your browser, in a native window, and in the tests.

A test proves something about the browser only if the browser build draws the same pixels as the test build. Thus the engine contains a fixed drawing. The drawing uses each tool. It has a soft wash, a calligraphy nib, a ribbon, a dry bristle brush, an oil brush and spray. It also has a fill, an eraser, and an undo and redo.

```zig
/// The display hash after `draw` on a new 640 by 400 document with two layers.
/// If a change to the engine changes the picture on purpose, run the tests,
/// examine the new picture, and update this value.
pub const hash: u32 = 0x3870db57;
```

*Quoted from the source: `hash` from `examples/paint/src/engine/demo.zig`.*

A native test draws the picture. Then the test compares a hash of the pixels with that number.

Before the site build, the browser build draws the same picture and compares its hash with the same number. If one pixel is different between the two builds, the build fails, and the site does not publish this page.

## The browser build

The engine is plain Zig with no dependencies. Thus the browser build needs no other tools. It uses the same compiler, with the target `wasm32-freestanding`:

```zig
/// The browser build. The function is public, thus the build.zig of the
/// guide can call it with its own path to `src/`. Both builds use one definition.
pub fn addWeb(b: *std.Build, src: std.Build.LazyPath, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const engine = b.createModule(.{
        .root_source_file = src.path(b, "engine.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "paint",
        .root_module = b.createModule(.{
            .root_source_file = src.path(b, "web.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    // A library of exported functions, not a program with a main. The page
    // calls the functions.
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}
```

*Quoted from the source: `addWeb` from `examples/paint/build.zig`.*

`freestanding` means that there is no operating system. The engine does not need an operating system, because it never opens a file or reads a clock.

The result is about 150 KB. About half of that size is the JSON parser that reads brush presets. The [Projects and Presets](https://www.ziglang.in/learn/paint/projects-and-presets/) chapter gives the measurement.

## The chapters

The chapters follow the engine from the pointer to the PNG file:

1. **Strokes**: change pointer samples at irregular distances into dabs at equal distances.
2. **Smoothing, pressure and scatter**: make a stroke look as if a hand drew it, and make it repeatable.
3. **The tip**: soft edges, flat tips, and tips that turn.
4. **Bristles and paper**: separate tracks for each hair, and a dry brush on the grain of the paper.
5. **Oil**: a brush that collects the paint below it, and becomes dry.
6. **Flow and opacity**: why the engine first puts a stroke in a separate buffer.
7. **Layers and the eraser**: premultiplied alpha, and why the eraser needs it.
8. **Undo**: keep only the pixels that changed, inside a memory budget.
9. **Fill**: a flood fill that uses a queue instead of recursion.
10. **Save a PNG**: write the picture as a PNG.
11. **Projects and presets**: keep the layers in a file format of this program, and brushes in JSON. Examine both when the program reads them again.
12. **Watercolour**: water and pigment that spread and dry on a grid. This is a separate experiment that you can run.
13. **A native window**: the same engine with raylib, and a cross-compiled build for Windows.

Each chapter shows the tests that examine it.

## Explain before you read the answer

The front end sends each pointer sample from the browser to the engine.

Some browsers send a fast movement as a small number of samples that are far apart. Other browsers send the same movement as many samples that are near each other.

Does the same movement draw the same stroke in both browsers?

Yes, it does. The engine does not put one mark for each sample. The engine moves along the path and puts a mark at a fixed distance, for all sets of samples. The next chapter shows how.
