# Projects and Presets

> A project file keeps the layers a PNG would merge. A preset keeps a brush. Both are input someone else wrote, so both are checked before anything changes.

A PNG is for sharing a finished picture. It is a bad way to keep working on one.

A PNG is flat. When it is saved, the layers are merged into one image. Opened again, nothing can say which paint was on which layer, so the eraser can no longer reveal the bottom layer. Two layers plus the size of the page can rebuild the picture you were working on. One merged PNG cannot.

So the studio has two more kinds of file:

- **Save project** keeps every layer, and which ones are visible.
- **Save brush** keeps a brush's settings as a **preset**: a name and the numbers that make the brush behave the way it does. A preset holds no pixels.

## The project format

Before any code, the format is written down, field by field, at the top of the file that implements it:

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

The [Binary Files](https://www.ziglang.in/learn/files/binary-files/) chapter builds a format the same way. The **magic** bytes say what kind of file this is. The **version** says which edition of the format, so a later program can change the format and still recognise an old file.

Each layer's pixels are compressed with zlib, the same compressor the [PNG writer](https://www.ziglang.in/learn/graphics/png/) uses. An empty layer of 640 by 400 is 1,024,000 bytes of zeros, and compresses to about a kilobyte.

<PaintSource file="src/engine/project.zig" decl="save" />

## Opening is reading someone else's bytes

Saving is easy, because our program wrote the data and trusts it.

Opening is different. The file might be from an older version, cut short by a failed download, damaged on a disk, or not a project at all. Opening reads input from outside the program, so every field is checked before it is used.

<PaintSource file="src/engine/project.zig" decl="OpenError" />

Each way a file can be wrong has its own error. The studio turns each one into a sentence a person can act on, and leaves the picture on screen untouched.

## Build the new document first

A failed open must not damage the work on screen.

So `open` builds a complete new document, separate from the one that is open. Only if every layer decodes and every check passes does the studio swap the new one in. If anything fails, `errdefer` frees the half-built document and the open picture was never touched.

<PaintSource file="src/engine/project.zig" decl="open" />

## A small file can ask for a lot of memory

The header says how big the picture is, and the document is allocated from that.

Eight layers of 4096 by 4096 pixels is 512 MB. A file only 16 bytes long can ask for that, with nothing behind its header.

So before allocating anything, `open` walks the layer table once. It reads each layer's size and checks that the bytes are really there, and that nothing follows the last layer. A file that lies about its contents fails here, before the big allocation.

A test proves it with an allocator that refuses every request. If `open` asked for memory before checking, the test would see `OutOfMemory` instead of `Truncated`.

## Checks inside the pixels

Two more checks look inside the compressed pixels.

A layer must decompress to exactly `width × height × 4` bytes. `open` reads that many, then asks for one more. A layer that is short fails the first read. One that is long has a byte left for the second.

And every pixel must be **premultiplied**, as the [Layers](https://www.ziglang.in/learn/paint/layers-and-the-eraser/) chapter explains: no colour channel larger than the alpha. The engine never writes such a pixel, so finding one means the file is damaged or was not written by this program.

## Brush presets

A preset is small, and a person may want to read or edit one. So presets are JSON:

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

Fields the file leaves out take the default brush's values. Fields this program does not know are skipped, so a preset from a later version still opens if the fields it knows are valid.

## 0.2, not 0.20000000298023224

The first preset this code wrote said `"aspect": 0.20000000298023224`.

The brush stores its settings as `f32`. `std.json` writes an `f32` by first widening it to `f64`, and the `f32` nearest to 0.2 is not exactly 0.2. Widened, the difference shows.

The file was correct, and it read back to the same brush. But a preset is meant to be read and edited by a person, and that number is not what anyone typed.

So `write` turns each setting into the shortest decimal that reads back as the same `f32`, which is what Zig's `{d}` format prints, and stores that as an `f64`. JSON then prints `0.2`:

<PaintSource file="src/engine/preset.zig" decl="decimal" />

Reading the file narrows `0.2` back to an `f32`, and gets the same bits the brush had. The round-trip test checks that.

## Refuse, do not repair

The brush already has a function that moves every setting into range: `sanitized`, in `brush.zig`. Every stroke runs its brush through it, so a slider can never hand the engine a value it cannot draw with.

A preset file must not rely on it. A file with a radius of −3 is a damaged file. Quietly turning −3 into 0.5 would hide the damage and give the person a brush they never made.

But `sanitized` is still useful here, as the definition of a valid brush. A brush is valid exactly when sanitizing it changes nothing:

<PaintSource file="src/engine/preset.zig" decl="parse" />

NaN never equals itself, so a NaN setting fails the same comparison. No list of ranges is repeated, so the preset check and the sliders cannot disagree.

## What JSON costs

The browser build was 49 KB before files. It is 146 KB after.

Taking out one function at a time and building again shows where the 97 KB went:

| part | adds |
|---|---|
| reading a preset with `std.json` | 67 KB |
| opening a project (zlib decompression) | 15 KB |
| writing presets and projects, and the rest | 15 KB |

`std.json` is general: it can parse any JSON into any Zig type, which is what makes `parseFromSlice(File, ...)` one line. That generality is most of the cost. A hand-written parser for exactly this one shape would be smaller, and would be a second piece of code to keep correct.

The page loads the engine only when you press Start, so the cost is paid once, by people who use the studio. For a program that loaded on every page, it would be worth writing the small parser.

## Checks

A saved project opens with the same layers, visibility and active layer:

<PaintSource file="src/engine/project.zig" decl="a saved project opens with the same layers, visibility and active layer" />

Each kind of damage gives its own error:

<PaintSource file="src/engine/project.zig" decl="each kind of damage is rejected with its own error" />

The file cut at every possible length, and every byte flipped in turn. A cut file must never open. A flipped byte may still open, if it lands somewhere that decompresses to valid pixels, but nothing may crash, and the testing allocator fails the test if anything leaks:

<PaintSource file="src/engine/project.zig" decl="every truncation and every flipped byte is rejected or opens cleanly, and nothing leaks" />

The 512 MB header:

<PaintSource file="src/engine/project.zig" decl="a header asking for 512 MB with no data behind it allocates nothing" />

There is also a **fuzz test**. `zig build test --fuzz` runs it with inputs the fuzzer generates and mutates, looking for any byte sequence that crashes `open`. An ordinary test run gives it only the valid file it starts from.

Presets written the way a person would type them:

<PaintSource file="src/engine/preset.zig" decl="settings are written as typed: 0.2, not 0.20000000298023224" />

And presets, refused for each reason:

<PaintSource file="src/engine/preset.zig" decl="a bad preset is refused with a reason, never repaired" />

## Explain before reading the answer

A project file from version 2 of this program arrives. Version 2 added a field to the header.

Should version 1 try to open it, skipping the field it does not know?

No. Version 1 cannot know where the new field is or how long it is, so it cannot know where the layers start. It refuses with `NewerVersion`, which tells the person exactly what to do: update the program. A preset is different, because JSON names every field, so an unknown one can be skipped safely.
