# Advanced Formatting

> Custom format methods, and the format specifiers that changed.

In Zig, a custom `format` method takes only a `*std.Io.Writer`. `print` calls the method only when the format string asks for it with `{f}`. Width, fill and alignment go after a colon, as in `{d:0>4}`. The formatter does that work, not the type.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Point = struct {
    x: i32,
    y: i32,

    // The `{f}` specifier uses a `format` method that takes a
    // `*std.Io.Writer`. Older Zig also gave a fmt string and options to the
    // method. That signature no longer applies.
    pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({d}, {d})", .{ self.x, self.y });
    }
};

const Colour = enum { red, green, blue };

test "{f} calls a custom format method" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{f}", .{Point{ .x = 1, .y = 2 }});
    try expect(std.mem.eql(u8, text, "(1, 2)"));
}

test "{t} prints an enum tag name" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{t}", .{Colour.green});
    try expect(std.mem.eql(u8, text, "green"));
}

test "{any} falls back to a structural dump" {
    var buf: [128]u8 = undefined;
    const text = try std.mem.print(&buf, "{any}", .{[_]u8{ 1, 2, 3 }});
    // The exact text can change, but the text contains the elements.
    try expect(std.mem.find(u8, text, "1") != null);
}

test "format strings are checked at compile time" {
    // The wrong number of arguments is a compile error, not a runtime
    // error. A specifier that the type does not support is also a compile
    // error.
    var buf: [32]u8 = undefined;
    const ok = try std.mem.print(&buf, "{d} {s}", .{ 1, "two" });
    try expect(std.mem.eql(u8, ok, "1 two"));
}

test "writing to a list" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("{f}", .{Point{ .x = 3, .y = 4 }});
    try expect(std.mem.eql(u8, out.written(), "(3, 4)"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`03-standard-library.advanced-formatting`)*

## The shape of a custom `format` method changed

Zig 0.15 rewrote the `format` method. The method now takes only a writer:

```zig
pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("({d}, {d})", .{ self.x, self.y });
}
```

The old signature also received the format string and an options struct. That signature no longer applies. A tutorial that shows `format(self,
comptime fmt: []const u8, options: FormatOptions, writer: anytype)` is older than the change.

The reason for the change explains the rest of this page. In the old design, the `format` method of each type had to parse the format string itself. Each method decided what `{d:>8}` meant for its type. Thus each implementation was slightly different, and most implementations ignored the options completely.

Now a type tells one time how it prints. The formatter controls the specifiers for width and alignment.

## `{f}` calls the method

`{}` and `{any}` do **not** use a custom `format` method. You must ask for the method with `{f}`:

```zig
try writer.print("{f}", .{point});   // (1, 2)
```

This rule is the other half of the same change. It often breaks code that you port from an older version. In the old design, `{}` found your method. Thus a type with a `format` method printed correctly in all places, and you did not have to ask.

Now `{}` prints the struct as the compiler sees it, and `{f}` asks for your method. The benefit is that the call site now shows which output you get: the type's own rendering or the generic dump. In the old design, you could not tell.

## Common specifiers

| Specifier | Prints |
| --- | --- |
| `{d}` | a number in decimal |
| `{x}` / `{X}` | hex, lower or upper case; also works on byte slices |
| `{b}` / `{o}` | binary, octal |
| `{s}` | a string, which is a `[]const u8` printed as text |
| `{c}` | one byte as a character |
| `{any}` | the generic dump, for any type |
| `{f}` | the type's own `format` method |
| `{t}` | the name of an enum tag or an error |
| `{!}` | an error union, as `error.Name` |
| `{*}` | the address in a pointer |

Width, fill and alignment come after a colon:

- `{d:0>4}` adds zeros on the left until the text has four characters.
- `{s:<20}` aligns the text on the left in a field of twenty characters.
- `{d:.2}` sets the number of decimal places for a float.

The compiler checks each specifier against the tuple that you give. A `{d}` for a string is a build error, not a runtime error. Four specifiers with three arguments is also a build error. Because of this check, the format string must be a comptime value.

## `{t}` for tag names

`{t}` prints the tag name of an enum or the name of an error. In older code, each call site called `@tagName`. `{t}` replaces that practice:

```zig
try writer.print("{t}", .{Colour.green});   // green
```

## Combine writers

`std.Io.Writer.Allocating` gives you an in-memory writer that can grow. It is the usual way to make a string from formatted parts:

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try out.writer.print("{f}", .{point});
out.written();   // []const u8
```

For a string with a known maximum size, use `std.mem.print`. It writes into a buffer on the stack and returns the slice that it filled. It does not use an allocator. If the text is too long for the buffer, it returns an error.

- To format a number into a field of fixed size, use `std.mem.print`.
- When the length depends on the data, use `Allocating`.

```zig
var buf: [32]u8 = undefined;
const text = try std.mem.print(&buf, "{d}%", .{percent});
```

These two functions replace `std.fmt.bufPrint` and `std.fmt.allocPrint`. The new names are `std.mem.print` and `Allocator.print`.

Both use the same `std.Io.Writer` interface that a file or a socket implements. Thus the same `print` call works with all of them. To test a function that takes a `*std.Io.Writer`, give the function a buffer. See [readers and writers](https://www.ziglang.in/learn/standard-library/readers-and-writers/).
