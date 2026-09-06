# Anonymous Structs

> Inferred struct literals, and tuples.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}

test "anonymous struct literal" {
    // The type is inferred from context, so the name need not be written.
    try expect(describe(.{ .x = 1, .y = 2 }) == 3);
}

test "tuples are anonymous structs with numeric fields" {
    const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
    try expect(tuple.len == 3);
    try expect(tuple[0] == 1);
    try expect(tuple[1] == true);
}

test "tuples hold mixed types" {
    const pair = .{ @as(u32, 7), "seven" };
    try expect(pair[0] == 7);
    try expect(std.mem.eql(u8, pair[1], "seven"));
}

test "this is how format arguments work" {
    // `.{ a, b }` in a print call is just a tuple; the format string is
    // checked against it at compile time.
    var buf: [32]u8 = undefined;
    const text = try std.mem.print(&buf, "{s}={d}", .{ "x", 42 });
    try expect(std.mem.eql(u8, text, "x=42"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.anonymous-structs`)*

`.{ ... }` is a struct literal whose type comes from context. When the target
type is known (a parameter, a field, a return type), the name is redundant:

```zig
describe(.{ .x = 1, .y = 2 });
```

The same leading dot appears wherever a type can be inferred: `.north` for an
enum tag, `.{ .ok = value }` for a union variant, `.{}` for a struct whose
fields all have defaults. It is one rule, not four. The dot means "you already
know the type, so I am not going to repeat it".

Where the target type is *not* known, there is nothing to infer from and the
literal has to be named:

```zig
const p = Point{ .x = 1, .y = 2 };   // no context, so say the type
```

## Anonymous struct types

A struct type can also be written inline, which is what the snippet's
`describe` does:

```zig
fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}
```

Useful for a one-off shape that does not deserve a name, and for returning
several values at once without declaring a type for the pair. Two separately
written anonymous struct types are distinct types even if their fields match,
so this is for local convenience rather than for anything crossing an
interface.

## Tuples

Leave out the field names and you get a tuple: a struct whose fields are
numbered. Tuples have `.len`, support indexing, and may mix types freely:

```zig
const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
tuple[0];   // 1
tuple.len;  // 3
```

Index with a comptime-known constant: `tuple[i]` for a runtime `i` cannot
work, because each element has its own type. A runtime index would mean the
type of the expression depends on a runtime value, and there is no such thing.
Walk them with [`inline for`](https://www.ziglang.in/learn/language-basics/inline-loops/), which
compiles the body separately per element and so can give each one a different
type.

The `++` operator concatenates tuples, which is how variadic-looking helpers
build up an argument list at compile time.

## This is what format arguments are

```zig
std.mem.print(&buf, "{s}={d}", .{ "x", 42 });
```

That second argument is just a tuple. There is no varargs mechanism in Zig.
`print` takes one value that happens to be a struct, walks it with `inline
for`, and checks it against the format string at compile time. A mismatched
`{d}` is a compile error, not a runtime surprise.

Once you see it, the whole design follows. Passing the wrong number of
arguments is a compile error because the tuple has a length. Passing a struct
where `{d}` expects a number is a compile error because the field's type is
known. There is no `printf` format-string vulnerability to have, because the
format string and the arguments are checked against each other before the
program runs.

It also explains the empty case. A call with no arguments still passes a
tuple, which is why `.{}` appears at the end of every `print` that
interpolates nothing.
