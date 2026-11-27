# Anonymous Structs

> Struct literals with an inferred type, and tuples.

Zig has anonymous structs in two forms:

- A struct type that you write inline, at the place where you use it.
- A tuple. A tuple is a struct with numbered fields instead of named fields.

The argument list that you give to `print` is a tuple.

```zig
const std = @import("std");
const expect = std.testing.expect;

fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}

test "anonymous struct literal" {
    // The compiler infers the type from the context. Thus you do not write the name.
    try expect(describe(.{ .x = 1, .y = 2 }) == 3);
}

test "tuples are anonymous structs with numeric fields" {
    const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
    try expect(tuple.len == 3);
    try expect(tuple[0] == 1);
    try expect(tuple[1] == true);
    // The name of the field is `1`. `1` is not a valid identifier, thus the
    // field syntax needs `@""`. The two forms read the same field.
    try expect(tuple.@"1" == true);
    try expect(@field(tuple, "2") == 2.5);
}

test "tuples hold mixed types" {
    const pair = .{ @as(u32, 7), "seven" };
    try expect(pair[0] == 7);
    try expect(std.mem.eql(u8, pair[1], "seven"));
}

test "this is how format arguments work" {
    // `.{ a, b }` in a print call is only a tuple. The compiler compares the
    // format string with the tuple at compile time.
    var buf: [32]u8 = undefined;
    const text = try std.mem.print(&buf, "{s}={d}", .{ "x", 42 });
    try expect(std.mem.eql(u8, text, "x=42"));
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.anonymous-structs`)*

`.{ ... }` is a struct literal. The literal gets its type from the context. When the compiler knows the target type (a parameter, a field, a return type), you do not have to write the name:

```zig
describe(.{ .x = 1, .y = 2 });
```

The same dot at the start occurs in each place where the compiler can infer a type:

- `.north` for an enum tag.
- `.{ .ok = value }` for a union variant.
- `.{}` for a struct with a default value for each field.

These are one rule, not four. The dot means "you know the type, so I do not write the type again".

If the compiler does not know the target type, it has no type to infer. Then you must write the name of the type in the literal:

```zig
const p = Point{ .x = 1, .y = 2 };   // no context, so say the type
```

## Anonymous struct types

You can also write a struct type inline. The `describe` function in the snippet does this:

```zig
fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}
```

An inline type is useful for a shape that you use one time and that does not need a name. It is also useful when a function returns several values and you do not want to declare a type for them.

Two anonymous struct types that you write separately are different types, also when their fields are the same. Thus, use them for local convenience. Do not use them for types that cross an interface.

## Tuples

If you do not write the field names, you get a tuple. A tuple is a struct with numbered fields. A tuple has `.len`, you can use an index on it, and its fields can have different types:

```zig
const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
tuple[0];     // 1
tuple.@"1";   // true
tuple.len;    // 3
```

The numbers are the field names. The name of the first field is `0`, the name of the second field is `1`, and so on.

A name cannot start with a digit, thus `tuple.1` does not parse. Put the name in `@""` instead. `tuple.@"1"` is usual field access. Zig uses the same escape for each name that is not a plain identifier.

`tuple[1]` is a shorter form of the same access. When the name is a string that you make at compile time, `@field(tuple, "1")` reads the same field.

The index must be a constant that the compiler knows. `tuple[i]` with a runtime `i` cannot work, because each element has its own type. With a runtime index, the type of the expression would depend on a runtime value. Zig does not allow that.

To visit each element, use [`inline for`](https://www.ziglang.in/learn/language-basics/inline-loops/). `inline for` compiles the body one time for each element. Thus each element can have a different type.

The `++` operator joins tuples. Helpers that look variadic use `++` to make an argument list at compile time.

## Format arguments are a tuple

```zig
std.mem.print(&buf, "{s}={d}", .{ "x", 42 });
```

The second argument is only a tuple. Zig has no mechanism for varargs. `print` takes one value, and that value is a struct. `print` visits the struct with `inline for`, and compares it with the format string at compile time. A `{d}` that does not match is a compile error, not a runtime error.

The arguments are a tuple, and some rules follow from that:

- The wrong number of arguments is a compile error, because the tuple has a length.
- A struct where `{d}` expects a number is a compile error, because the compiler knows the type of the field.
- Zig has no `printf` format-string vulnerability. The compiler compares the format string and the arguments before the program runs.

The tuple also explains the empty case. A call with no arguments still gives a tuple to `print`. Thus `.{}` occurs at the end of each `print` call that inserts no values.
