# A Native Window

> The same engine in a desktop window with raylib. Linux builds for Windows with one flag. A licence, not the compiler, stops a build for macOS.

The studio on the first page is the engine in a browser.

The same engine also runs in a desktop window. **raylib** draws the window. raylib is a small C library for windows, graphics and input.

The front end is one file, `native.zig`. It does the same work as the browser front end. It reads input, calls the engine, and copies the changed rectangle to the screen.

```
cd examples/paint
./fetch-raylib.sh      # once: download raylib's C at a pinned commit
zig build run          # open the window
```

## raylib as C, not as a package

The program uses raylib as a folder of C files, and its own `build.zig` compiles them.

`fetch-raylib.sh` downloads the files at a fixed commit. The [Lane Dodger](https://www.ziglang.in/learn/lane-dodger/the-build/) game uses the same commit. That chapter tells why the program vendors the C and does not use a Zig package. The build script of a package must stay current with Zig master, and the build script of raylib often is not current.

This is the full raylib build:

```zig
fn raylibModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // This C does not come from this project. The UBSan runtime would only
        // report problems in a fixed upstream release.
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{ .name = "raylib", .linkage = .static, .root_module = mod });

    inline for (.{
        .{ "_GNU_SOURCE", "" },
        .{ "GL_SILENCE_DEPRECATION", "199309L" },
        .{ "PLATFORM_DESKTOP_GLFW", "" },
        .{ "GRAPHICS_API_OPENGL_33", "" },
        .{ "SUPPORT_MODULE_RSHAPES", "1" },
        .{ "SUPPORT_MODULE_RTEXTURES", "1" },
        .{ "SUPPORT_MODULE_RTEXT", "1" },
        // A paint program makes no sound and loads no 3D models.
        .{ "SUPPORT_MODULE_RAUDIO", "0" },
        .{ "SUPPORT_MODULE_RMODELS", "0" },
    }) |macro| mod.addCMacro(macro[0], macro[1]);

    const windows = target.result.os.tag == .windows;
    mod.addCMacro(if (windows) "_GLFW_WIN32" else "_GLFW_X11", "");
    mod.addIncludePath(b.path(raylib_root ++ "/platforms"));
    mod.addIncludePath(b.path(raylib_root ++ "/external/glfw/include"));
    mod.addCSourceFiles(.{
        .root = b.path(raylib_root),
        .files = &.{ "rcore.c", "rshapes.c", "rtextures.c", "rtext.c", "rglfw.c" },
        .flags = &.{"-std=gnu99"},
    });
    const libs: []const []const u8 = if (windows)
        &.{ "opengl32", "gdi32", "winmm", "user32", "shell32" }
    else
        &.{ "GL", "X11", "Xrandr", "Xinerama", "Xi", "Xcursor" };
    for (libs) |name| mod.linkSystemLibrary(name, .{});

    const translated = b.addTranslateC(.{
        .root_source_file = b.path(raylib_root ++ "/raylib.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const rl = translated.createModule();
    rl.linkLibrary(lib);
    return rl;
}
```

*Quoted from the source: `raylibModule` from `examples/paint/build.zig`.*

`addTranslateC` reads `raylib.h` and changes it into a Zig module. Then the front end calls `rl.InitWindow`, `rl.DrawTexture` and the other functions as Zig functions.

A paint program makes no sound and loads no 3D models. Thus two macros turn off the audio and model modules. Five C files remain.

## The front end

The window shows a texture with the size of the document. In each frame, the loop does these steps:

1. It reads the mouse.
2. It calls the engine.
3. It uploads only the rectangle that `render` returns as changed.

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var doc: engine.Document = try .init(gpa, width, height, engine.default_layers, engine.default_history_budget);
    defer doc.deinit();

    const headless = build_options.frames != null;
    if (headless) {
        rl.SetTraceLogLevel(rl.LOG_WARNING);
        // A smoke run draws the demo picture of the engine. Thus CI makes sure
        // that a window can show the picture that the tests drew.
        try engine.demo.draw(&doc);
    }

    rl.InitWindow(width, height + bar, "Paint");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);

    // The texture has the size of the document. At the start, it is a copy
    // of the display. After that, the loop uploads only changed rectangles.
    _ = doc.render();
    const texture = rl.LoadTextureFromImage(.{
        .data = doc.display.ptr,
        .width = width,
        .height = height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    });
    defer rl.UnloadTexture(texture);

    // Space for a copy of one changed rectangle, row by row. A texture update
    // needs the pixels of the rectangle next to each other.
    const scratch = try gpa.alloc(engine.Rgba, width * height);
    defer gpa.free(scratch);

    var preset: usize = 0;
    var color: usize = 0;
    var size: f32 = 8;
    var tool: Tool = .paint;
    var seed: u32 = 1;
    var drawing = false;
    var frame: usize = 0;
    var message: [:0]const u8 = "";

    while (!rl.WindowShouldClose()) : (frame += 1) {
        if (build_options.frames) |n| if (frame >= n) break;

        // ---- keyboard --------------------------------------------------------
        const ctrl = rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL);
        if (!drawing) {
            if (ctrl and rl.IsKeyPressed(rl.KEY_Z)) _ = doc.undo();
            if (ctrl and rl.IsKeyPressed(rl.KEY_Y)) _ = doc.redo();
            if (ctrl and rl.IsKeyPressed(rl.KEY_S)) {
                message = if (save(init.io, &doc)) "Saved painting.png" else |_| "Saving failed";
            }
            if (!ctrl) {
                for (0..presets.len) |i| {
                    if (rl.IsKeyPressed(rl.KEY_ONE + @as(c_int, @intCast(i)))) preset = i;
                }
                if (rl.IsKeyPressed(rl.KEY_P)) tool = .paint;
                if (rl.IsKeyPressed(rl.KEY_E)) tool = .erase;
                if (rl.IsKeyPressed(rl.KEY_F)) tool = .fill;
                if (rl.IsKeyPressed(rl.KEY_C)) color = (color + 1) % colors.len;
                if (rl.IsKeyPressed(rl.KEY_LEFT_BRACKET)) size = @max(1, size - 2);
                if (rl.IsKeyPressed(rl.KEY_RIGHT_BRACKET)) size = @min(80, size + 2);
                if (rl.IsKeyPressed(rl.KEY_L)) _ = doc.setActiveLayer(1 - doc.active_layer);
            }
        }

        // ---- mouse -------------------------------------------------------------
        // A mouse has no pressure, and the browser sends 0.5 for a mouse. The
        // native build does the same, thus the two builds draw the same stroke.
        const m = rl.GetMousePosition();
        const p: engine.Point = .{ .x = m.x, .y = m.y, .pressure = 0.5 };
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and m.y < height) {
            switch (tool) {
                .fill => _ = doc.fillAt(@intFromFloat(@max(m.x, 0)), @intFromFloat(@max(m.y, 0)), colors[color]) catch false,
                .paint, .erase => {
                    var brush = presets[preset].brush;
                    brush.radius = size;
                    brush.color = colors[color];
                    brush.seed = seed;
                    doc.beginStroke(brush, if (tool == .erase) .eraser else .brush, p);
                    drawing = true;
                },
            }
        } else if (drawing and rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            doc.moveStroke(p);
        } else if (drawing) {
            doc.endStroke();
            drawing = false;
            seed += 1;
        }
        if (drawing and !rl.IsWindowFocused()) {
            // The window lost focus during a stroke. Drop the stroke. The browser
            // does the same.
            doc.cancelStroke();
            drawing = false;
        }

        // ---- picture -----------------------------------------------------------
        const r = doc.render();
        if (!r.isEmpty()) {
            var i: usize = 0;
            var y = r.y0;
            while (y < r.y1) : (y += 1) {
                const row = @as(usize, y) * width;
                @memcpy(scratch[i..][0..r.width()], doc.display[row + r.x0 .. row + r.x1]);
                i += r.width();
            }
            rl.UpdateTextureRec(texture, .{
                .x = @floatFromInt(r.x0),
                .y = @floatFromInt(r.y0),
                .width = @floatFromInt(r.width()),
                .height = @floatFromInt(r.height()),
            }, scratch.ptr);
        }

        rl.BeginDrawing();
        rl.ClearBackground(.{ .r = 40, .g = 42, .b = 54, .a = 255 });
        rl.DrawTexture(texture, 0, 0, rl.WHITE);
        var status_buf: [160]u8 = undefined;
        const status = std.mem.printSentinel(&status_buf, "{s}  {s}  size {d}  {s} layer   1-9 brush  P/E/F  [ ]  C colour  L layer  Ctrl+Z/Y  Ctrl+S   {s}", .{
            presets[preset].name,
            @tagName(tool),
            @as(u32, @intFromFloat(size)),
            if (doc.active_layer == 0) "bottom" else "top",
            message,
        }, 0) catch "";
        const c = colors[color];
        rl.DrawRectangle(6, height + 6, 16, 16, .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 });
        rl.DrawText(status.ptr, 28, height + 8, 12, .{ .r = 220, .g = 222, .b = 230, .a = 255 });
        rl.EndDrawing();
    }

    if (build_options.screenshot) |path| {
        // raylib wants a C string, ending in a zero byte.
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        rl.TakeScreenshot((try std.mem.printSentinel(&path_buf, "{s}", .{path}, 0)).ptr);
    }
}
```

*Quoted from the source: `main` from `examples/paint/src/native.zig`.*

The texture update of raylib needs the pixels of the rectangle next to each other in memory. In `display`, the pixels are not next to each other: each row of the rectangle is one row of a 640-pixel image. Thus the code first copies the rows into `scratch`.

A mouse has no pressure. Thus each point gets 0.5, which is the value that browsers send for a mouse. The window and the studio draw the same stroke for the same movement.

## Cross-compile

Zig compiles for other operating systems with one flag:

```
zig build native -Dtarget=x86_64-windows
```

On Linux, this command builds a `paint.exe` of about 1.3 MB that works. You do not have to install anything first.

The cross-compile works because of the libraries that raylib needs from Windows: `opengl32`, `gdi32`, `winmm`, `user32` and `shell32`. The compiler contains the import libraries for these, from the MinGW project. The `build.zig` above only selects `_GLFW_WIN32` instead of `_GLFW_X11` and gives the names of those libraries.

One more line is important on Windows:

```zig
if (target.result.os.tag == .windows) exe.subsystem = .windows;
```

A Windows program is a console program or a window program. When you double-click a console program, it opens a terminal window behind the paint window. `.windows` selects a window program.

CI builds the Windows `.exe` on each run, from a Linux computer. If a change in Zig or raylib breaks the Windows build, the nightly build fails. CI does not run the `.exe`, because it has no Windows computer.

## The limits of cross-compilation

For other Linux systems, a build is more difficult. For macOS, a build from Linux is not possible.

- **Linux on a different CPU**, such as a 64-bit ARM board, needs the X11 header files for that system. Zig does not contain them, thus they must come from that system. They are only headers, thus the build is possible. But it is not one flag.
- **macOS** needs the Apple SDK: the headers and libraries for Cocoa, IOKit and OpenGL that raylib uses on a Mac. Zig does not contain them, and the Apple licence does not let other people ship them. The compiler can do the job, but nobody can legally copy the files that it needs.

Thus you must build the macOS version on a Mac, where the SDK is already installed. GitHub gives Mac computers for CI. Thus a macOS build costs more, but it is possible.

## A smoke test without a screen

CI has no screen. CI runs the window inside **Xvfb**, a virtual display that draws into memory.

`-Dframes=30` makes the program draw the demo picture of the engine, show it for 30 frames, and stop. `-Dshot` saves the last frame:

```
zig build native -Dframes=30 -Dshot=demo-native.png
xvfb-run ./zig-out/bin/paint
```

The compile proves that the raylib calls still agree with the headers. The run proves that the window opens and that raylib draws the texture.

## Explain before you read the answer

For the same movement, the browser studio and the native window send the same points to the engine.

Do they draw exactly the same pixels?

The engine does. With the same calls, it calculates the same picture on all computers. The demo check in the first chapter proves this for the browser and native builds.

The calls can be different. A browser can send more than one sample in each frame. The studio gives all of the samples to the engine. raylib reads the mouse one time in each frame. Thus a fast stroke gets more points in the browser. The spacing from the [Strokes](https://www.ziglang.in/learn/paint/strokes/) chapter keeps the dabs at equal distances in both cases. But where the path bends between samples, the two paths are slightly different.
