# Onto the Screen

> The same buffer, given to X11 through translate-c, and what changes on Wayland.

A file write goes in one direction: you make bytes, and then the work is complete. A window needs messages in the two directions. The display server decides when you can paint, asks if your program is still alive, and reports input. If your program does not do its part of this exchange, the window stays blank, freezes, or the server kills it.

Three things are different from [Write an Image File](../image-files/).

**The pixels are wider.** X11 and Wayland both want 32 bits per pixel, not 24. On a little-endian computer, both want a `u32` that holds `0x00RRGGBB`. In memory, this value is B, G, R, X. When you write full `u32` values, the byte order is correct without more work. For this reason, the framebuffer in this section uses 32 bits from the first chapter.

**Two programs can share the buffer.** A file write is a copy. To put pixels on screen, a copy is not always necessary. Wayland's `wl_shm` gives the compositor a file descriptor for the same pages that you drew into, and no copy occurs. X11's `XPutImage` copies the pixels to the server. The `MIT-SHM` extension exists to prevent that copy.

**One drawing is not sufficient.** The server tells you when to paint, and it asks again later.

## Xlib, the short version

Open a display, create a window and map it. Then answer the events. Xlib needs much less setup code than Wayland. It still runs on all Linux desktops, also under XWayland on a Wayland desktop.

```zig
const std = @import("std");

/// translate-c makes this module from the headers named above. `@cImport`
/// is not in the language now. C now comes through a build-system step.
const c = @import("c");

const width: c_uint = 640;
const height: c_uint = 480;

fn drawFrame(pixels: []u32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u32 = @intCast((x * 255) / (width - 1));
            const g: u32 = @intCast((y * 255) / (height - 1));
            // 0x00RRGGBB. On a little-endian computer, this value is in memory
            // as B, G, R, X. A 24-bit TrueColor visual expects that order.
            pixels[y * width + x] = (r << 16) | (g << 8) | 80;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    const display = c.XOpenDisplay(null) orelse return error.NoDisplay;
    defer _ = c.XCloseDisplay(display);

    // Xlib's `DefaultScreen`, `RootWindow`, `DefaultVisual` and similar names
    // are function-like macros that read a private struct. translate-c cannot
    // give them a meaning. Each macro has a real function behind it.
    const screen = c.XDefaultScreen(display);
    const root = c.XRootWindow(display, screen);
    const visual = c.XDefaultVisual(display, screen);
    const depth = c.XDefaultDepth(display, screen);
    const gc = c.XDefaultGC(display, screen);

    if (depth != 24 and depth != 32) return error.UnsupportedVisual;

    const window = c.XCreateSimpleWindow(
        display,
        root,
        0,
        0,
        width,
        height,
        0,
        c.XBlackPixel(display, screen),
        c.XBlackPixel(display, screen),
    );
    defer _ = c.XDestroyWindow(display, window);

    _ = c.XStoreName(display, window, "Zig pixels");
    _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask);

    // Without this call, the close button closes the connection. It does not
    // send an event that the program can use.
    var wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", 0);
    _ = c.XSetWMProtocols(display, window, &wm_delete, 1);

    // XCreateImage takes ownership. XDestroyImage frees this memory with
    // `free()`. Thus the memory must come from the C allocator, not a Zig one.
    const data: [*]u32 = @ptrCast(@alignCast(std.c.malloc(width * height * 4) orelse
        return error.OutOfMemory));
    drawFrame(data[0 .. width * height]);

    const image = c.XCreateImage(
        display,
        visual,
        @intCast(depth),
        c.ZPixmap,
        0,
        @ptrCast(data),
        width,
        height,
        32, // bitmap_pad: rows start on 32-bit boundaries
        0, // bytes_per_line: 0 means "calculate it from width"
    ) orelse {
        std.c.free(data);
        return error.ImageFailed;
    };
    // XDestroyImage is another macro. It calls through the function table of
    // the image, and Zig can call through that table directly.
    defer _ = image.*.f.destroy_image.?(image);

    _ = c.XMapWindow(display, window);

    var event: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(display, &event);
        switch (event.type) {
            // X11 keeps no copy of your pixels. Each time the window becomes
            // visible again, the server asks the client to paint it again.
            // Thus the program keeps the image. It does not blit it one time.
            c.Expose => _ = c.XPutImage(display, window, gc, image, 0, 0, 0, 0, width, height),

            c.KeyPress => {
                if (c.XLookupKeysym(&event.xkey, 0) == c.XK_Escape) return;
            },

            c.ClientMessage => {
                if (event.xclient.data.l[0] == @as(c_long, @intCast(wm_delete))) return;
            },

            else => {},
        }
    }
}

// Marked `//! norun`: this program opens a window and then waits for a
// keypress. A CI step cannot wait for a keypress. CI still compiles it and
// links it against the real libX11 on each run. Thus a change in the Xlib
// headers, or in how Zig translates them, makes the build fail.
```

*Opens a window and waits for a keypress. A CI step cannot wait for a keypress. CI compiles the snippet and links it against the real libX11 on each run. (`09-graphics.x11-window`)*

When you write your own version, four details in that code are important.

**`@cImport` does not exist now.** C headers now come through a build-system step. In this repo, `//! link: X11` and `//! cinclude:` configure that step. `build.zig` makes a header, runs `addTranslateC` on it, and gives the result to the snippet as `@import("c")`. In your own project, use `b.addTranslateC(...)` and then `translate.createModule()`. [Import C](../../working-with-c/cimport/) shows the general shape.

**Xlib's `Default*` macros do not work after translation.** `DefaultScreen(dpy)`, `RootWindow`, `DefaultVisual` and `DefaultGC` all expand to member accesses on a private struct. translate-c cannot give those accesses a meaning. Each macro has a real function behind it (`XDefaultScreen`, `XRootWindow`, and others), thus call those functions.

`XDestroyImage` has the same problem, but a different solution. The macro expands to a call through the function table of the image. Zig can make that call directly:

```zig
_ = image.*.f.destroy_image.?(image);
```

**`XCreateImage` takes ownership of your pixels.** `XDestroyImage` frees them with `free()`. Thus the buffer must come from `std.c.malloc`, not from a Zig allocator. If you give it a block from a `GeneralPurposeAllocator`, the program calls `free` on a pointer that the C allocator never owned.

**X11 keeps no copy of your pixels.** Each time the window becomes visible again, the server sends `Expose`, and the client must paint again. For this reason, the program keeps the image. It does not blit the image one time and then discard it.

The close button also needs a registration. Register `WM_DELETE_WINDOW` through `XSetWMProtocols`. If you do not, a click on the close button closes the connection. You get no event that the program can use.

## What Wayland changes

Wayland is the newer protocol, and it is the default on most current Linux desktops. The drawing code is the same. All the code around it is different. All the differences go in the same direction: the compositor does less work for you.

**Discovery is a handshake.** You connect and ask for the registry. Then the compositor advertises its globals. You bind the globals that you need: `wl_compositor`, `wl_shm`, `xdg_wm_base`, `wl_seat`. This takes two roundtrips, not one, because the second roundtrip runs the listeners that you registered inside the first.

**A surface is not a window.** A bare `wl_surface` is only a rectangle of pixels. To make a window, put it in an `xdg_surface` and then in an `xdg_toplevel`. The toplevel holds the title and the app id.

**The first commit has no buffer.** The first commit asks the compositor for the initial `configure`. If you attach a buffer before that handshake is complete, the result is a protocol error. The `configure` handler does these steps:

1. It acks the serial.
2. It attaches the buffer.
3. It damages the surface.
4. It commits.

The window appears at that last commit.

**You must answer `xdg_wm_base.ping` with `pong`.** The ping is the check of the compositor that your client is alive. If you ignore the ping, the compositor kills your client as unresponsive. It is easy to forget the ping, because nothing fails until the compositor sends one.

**The shell protocol is not in the library.** `xdg-shell` comes as XML. At build time, `wayland-scanner` changes the XML into a header and glue code. A normal `addSystemCommand` step with `addOutputFileArg2` does this work. Thus the generated files can stay in the Zig cache, and you do not add them to the repo.

**There are no window decorations.** A compositor *can* offer to draw them through `zxdg_decoration_manager_v1`, but it does not have to. GNOME's Mutter does not advertise that global. A client that only posts a buffer gets exactly that buffer: no titlebar, no close button, and no way to move the window.

To draw your own decorations, do these steps:

1. Allocate a taller buffer.
2. Paint a strip.
3. Track the pointer.
4. Change a drag into a move request.

The compositor controls the window positions, not you.

The cursor image is also the work of the client. Until you call `wl_pointer.set_cursor`, the pointer is undefined. Thus, without a loaded cursor theme, the pointer disappears over your window.

Because of these differences, the X11 version above is one file, and a Wayland version is not.

## What neither version here does

**Animation.** The program shows one static frame. On Wayland, a `wl_surface_frame` callback controls the redraws, so that they occur at the same rate as the compositor. On X11, a timer or an idle loop controls the redraws.

**Resize.** A complete client allocates a new buffer at each `ConfigureNotify` or `configure`. If you use a fixed buffer again, X11 leaves the extra area unpainted, and Wayland scales the buffer.

**Double buffering.** If you write into a buffer that the compositor can read at the same time, you get a torn frame. A complete client keeps two buffers and waits for `wl_buffer.release`.

**Format negotiation.** The Wayland protocol makes `XRGB8888` mandatory. Thus you can safely assume it. The X11 code above checks only that the default visual is 24-bit or 32-bit. That is true on all desktops from the last twenty years. But it is not the same as a check of the formats that the server really offers.
