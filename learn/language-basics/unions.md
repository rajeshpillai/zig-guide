# Unions

> One of several types, sharing one allocation.

```zig
const std = @import("std");
const expect = std.testing.expect;

// A bare union has no tag: you must know which field is active.
const Payload = union {
    int: i64,
    float: f64,
};

const Tag = enum { int, float, none };

// A tagged union carries its tag, so `switch` can safely discriminate.
const Tagged = union(Tag) {
    int: i64,
    float: f64,
    none: void,
};

// `union(enum)` infers the tag enum for you.
const Inferred = union(enum) {
    text: []const u8,
    number: u32,
};

test "bare union" {
    var p = Payload{ .int = 42 };
    try expect(p.int == 42);
    // Reading `p.float` here would be illegal behaviour: wrong active field.
    p = Payload{ .float = 1.5 };
    try expect(p.float == 1.5);
}

test "switch on a tagged union" {
    var value = Tagged{ .int = 7 };
    switch (value) {
        .int => |*n| n.* += 1,
        .float => |*f| f.* *= 2,
        .none => {},
    }
    try expect(value.int == 8);
}

test "the tag is a real enum value" {
    const value = Tagged{ .float = 2.5 };
    try expect(@as(Tag, value) == .float);
}

test "inferred tag enum" {
    const v = Inferred{ .text = "hi" };
    switch (v) {
        .text => |t| try expect(t.len == 2),
        .number => unreachable,
    }
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.unions`)*

A union holds one of its fields at a time. The question is always: *which
one*?

## Bare unions do not know

```zig
const Payload = union { int: i64, float: f64 };
```

Reading a field that is not the active one is illegal behaviour. Bare unions
exist for C interop and for cases where the tag is already tracked elsewhere.

"Illegal behaviour" is the strong version, not "you get garbage". In a safety
build the wrong-field access is caught and panics. In ReleaseFast it is
undefined, and the optimiser is allowed to assume it never happens. So a bare
union is a promise you are making, and the only reason to make it is that
something outside the union already records the answer.

## Tagged unions do

```zig
const Tagged = union(Tag) { int: i64, float: f64, none: void };
```

Now the value carries its tag, `switch` can discriminate safely, and the
switch must be exhaustive. This is Zig's sum type, and it is what you almost
always want. It is the same construct that makes error unions and optionals
work.

Capturing by pointer in a prong lets you mutate in place:

```zig
switch (value) {
    .int => |*n| n.* += 1,
    ...
}
```

A `void` field is the way to say "this case carries nothing", which is how a
tagged union covers states that have no payload without inventing a dummy one.

## `union(enum)`

Writing `union(enum)` infers the tag enum from the field names, so you do not
have to declare and maintain a parallel `enum`. Use the explicit form only
when you need the enum as a named type of its own, or need to pin its values.

Get the tag with `@as(Tag, value)`, or compare directly against `.float` in a
`switch`. `std.meta.activeTag(value)` does the same thing with a name that
reads better outside a switch, and `@tagName` turns it into a string for
logging.

To build one where the variant is decided at compile time rather than written
literally, `@unionInit(T, "int", 5)` takes the field name as a comptime
string. That is what generic code uses when it is walking a type rather than
naming a case.

## What it costs

A tagged union is as large as its largest field plus the tag, plus whatever
padding alignment demands. Which means one enormous variant sets the size for
every value of the type, including the ones that carry nothing. When variants
differ wildly in size, the usual fix is to box the large one behind a pointer,
so the union holds a pointer instead of the payload.

The tag is an ordinary enum and can be given a type: `union(enum(u8))` pins it
to a byte. `packed union` exists for the bit-level cases and, like `packed
struct`, is for real boundaries rather than for saving a byte.

## Where you will actually use one

Anywhere a value is genuinely one of several shapes. A token from a lexer. A
node in a syntax tree. A message from a protocol. A configuration value that
can be a string or a number. The pattern to watch for in other people's code
is a struct with a "kind" field and several fields that are only valid for
some kinds. That is a tagged union written by hand, without the exhaustiveness
check.

The [tiny language](https://www.ziglang.in/learn/tiny-lang/) track builds a lexer, parser and
interpreter on exactly this construct, which is the best way to see why it
earns its place.
