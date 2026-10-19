//! title: libc From Zig
//! cinclude: stdio.h string.h
//! Two system headers, translated together, and called without a binding.

const c = @import("c");

pub fn main() void {
    // Zig string literals are already null-terminated. Thus you can give
    // them to a `[*c]const u8` parameter without a change.
    _ = c.printf("hello from C\n");

    const len = c.strlen("abc");
    _ = c.printf("strlen(\"abc\") = %d\n", @as(c_int, @intCast(len)));
}
