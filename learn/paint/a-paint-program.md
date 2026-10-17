# A Paint Program You Can Test

> A paint program you can use on this page, and the one rule that lets tests check every brush.

Press Start painting and draw.

<PaintStudio caption="Pick a brush, a size and a colour. Draw on the bottom or the top layer, erase, fill, undo, and save a PNG." />

A mouse works, and so does a finger. A pen with pressure draws thicker when you press harder.

Try the Calligraphy brush. Lines in one direction come out thin, and lines across them come out wide.

Draw on the bottom layer, switch to the top layer, draw again, and erase there. The bottom layer shows through where you erase.

## One rule

The program is in two parts.

The **engine** decides what every pixel becomes. It is about 2,100 lines of Zig, and about 1,050 more of tests.

The **front end** turns mouse and pen events into calls to the engine, and copies the engine's pixels onto the canvas.

The rule is that the engine never sees a mouse, a window or a clock.

Points go in. Pixels come out.

The engine's main type is a document. It holds the layers, the stroke being drawn, the history, and what the screen should show:

<PaintSource file="src/engine/document.zig" decl="Document" fields />

A front end calls a few methods on it.

A stroke is `beginStroke`, some `moveStroke` calls, and `endStroke`. Each call takes a point: an `x`, a `y` and a pressure.

After that, `render` brings `display` up to date and says which rectangle changed.

The front end copies that rectangle to the screen. It does nothing else.

## What the rule buys

Because the engine needs no window, a test can draw.

A test can start a stroke, move it, end it, and then check the pixels.

This one checks that a stroke looks the same while you draw it as it does after you let go:

<PaintSource file="src/engine/document.zig" decl="a stroke shows while drawing, and looks the same after it is committed" />

There are 80 tests like this, and none of them opens a window.

## The same pixels everywhere

The engine runs in three places: in your browser, in a native window, and in the tests.

A test only proves something about the browser if the browser build draws the same pixels as the test build.

So the engine carries a fixed drawing. It uses every tool: a soft wash, a calligraphy nib, a ribbon, a dry bristle brush, an oil brush, spray, a fill, an eraser, and an undo and redo.

<PaintSource file="src/engine/demo.zig" decl="hash" />

A native test draws the picture and compares a hash of its pixels with that number.

Before the site is built, the browser build draws the same picture and compares with the same number.

If one pixel differs between the two builds, the build fails and this page is not published.

## The browser build

The engine is plain Zig with no dependencies.

So the browser build needs no extra tools. It is the same compiler, pointed at `wasm32-freestanding`:

<PaintSource file="build.zig" decl="addWeb" />

`freestanding` means there is no operating system at all. The engine does not need one, because it never opens a file or reads a clock.

The result is about 150 KB. About half of that is the JSON parser that reads brush presets, as the [Projects and Presets](https://www.ziglang.in/learn/paint/projects-and-presets/) chapter measures.

## The chapters

The chapters follow the engine from the pointer to the PNG file.

1. **Strokes**: turning uneven pointer samples into evenly spaced dabs.
2. **Smoothing, pressure and scatter**: making a stroke look drawn by hand, and repeatable.
3. **The tip**: soft edges, flat tips, and tips that turn.
4. **Bristles and paper**: separate hair tracks, and a dry brush on paper grain.
5. **Oil**: a brush that picks up the paint it is dragged through, and runs dry.
6. **Flow and opacity**: why a stroke is built in its own buffer first.
7. **Layers and the eraser**: premultiplied alpha, and why the eraser needs it.
8. **Undo**: keeping only what changed, inside a memory budget.
9. **Fill**: a flood fill with a queue instead of recursion.
10. **Saving**: the picture as a PNG.
11. **Projects and presets**: keeping the layers in a file of our own, and brushes in JSON, and checking both when they come back.
12. **Watercolour**: water and pigment spreading and drying on a grid, a separate experiment you can run.
13. **A native window**: the same engine with raylib, and cross-compiling it for Windows.

Each chapter shows the tests that check it.

## Explain before reading the answer

The front end sends the engine every pointer sample the browser reports.

Some browsers report a fast movement as a few samples far apart. Others report the same movement as many samples close together.

Will the same movement draw the same stroke in both?

It will. The engine does not put one mark per sample. It walks along the path and puts a mark every few pixels, whatever the samples were. The next chapter shows how.
