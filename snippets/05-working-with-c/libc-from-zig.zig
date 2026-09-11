//! title: libc From Zig
//! cinclude: stdio.h string.h
//! Two system headers, translated together, called without a binding in sight.

const c = @import("c");

pub fn main() void {
    // Zig string literals are already null-terminated, so they pass to a
    // `[*c]const u8` parameter unchanged.
    _ = c.printf("hello from C\n");

    const len = c.strlen("abc");
    _ = c.printf("strlen(\"abc\") = %d\n", @as(c_int, @intCast(len)));
}
