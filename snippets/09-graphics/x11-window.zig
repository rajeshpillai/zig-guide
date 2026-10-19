//! title: The Same Buffer, in a Window
//! norun
//! link: X11
//! cinclude: X11/Xlib.h X11/Xutil.h X11/keysym.h
//! Xlib is the shortest route from a pixel buffer to a window on a Linux
//! desktop. Open a display, create a window, give the server your bytes.

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
