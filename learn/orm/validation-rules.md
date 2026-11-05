# Validation from Declarations

> Optional capabilities found with @hasDecl, the convention-over-configuration of Zig.

A Zig library finds optional behavior for each type with `@hasDecl` at compile
time. A schema that declares `pub const rules = .{ ... }` gets validation. A
schema without that declaration gets no validation code.

## The problem

Your library needs optional behavior for each type: validation rules on one
schema, custom serialization on another schema, and nothing on a third schema.
The classical answers are interfaces and inheritance, and Zig has neither.

Zig has a method that is better for libraries. The caller *declares* the
behavior that it supports. The library *asks* for that declaration at compile
time.

## The pattern

1. The convention: a schema can declare `pub const rules = .{ ... }`, with the
   names of its own fields.
2. The library checks `@hasDecl(T, "rules")` before it touches `rules`. If the
   declaration does not exist, there is no validation and no generated code.
3. `inline for` walks the rules. On each rule struct, `@hasField` decides which
   checks apply. Each lookup resolves at compile time. The work at runtime is
   only the comparisons.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Violation = struct {
    field: []const u8,
    rule: []const u8,
};

// The half in the library: walk the fields of the value. When the schema
// declares a rule for a field, apply the rule. A schema without rules always
// passes. An unknown rule name makes the build fail. The library does not
// ignore it.
fn validate(value: anytype) ?Violation {
    const T = @TypeOf(value);
    if (!@hasDecl(T, "rules")) return null;

    const info = @typeInfo(@TypeOf(T.rules)).@"struct";
    inline for (info.field_names) |field| {
        const rule = @field(T.rules, field);
        const v = @field(value, field);
        const R = @TypeOf(rule);

        if (@hasField(R, "min_len")) {
            if (v.len < rule.min_len) return .{ .field = field, .rule = "min_len" };
        }
        if (@hasField(R, "max")) {
            if (v > rule.max) return .{ .field = field, .rule = "max" };
        }
    }
    return null;
}

// The half in the caller: the rules are on the schema as one declaration,
// and they name the fields directly. A rule for a field that does not exist
// does not compile, because @field(value, ...) cannot resolve.
const User = struct {
    name: []const u8,
    age: u8,

    pub const rules = .{
        .name = .{ .min_len = 3 },
        .age = .{ .max = 130 },
    };
};

test "a valid value passes" {
    try expect(validate(User{ .name = "ada", .age = 36 }) == null);
}

test "violations name the field and the rule" {
    const short = validate(User{ .name = "al", .age = 36 }).?;
    try expect(std.mem.eql(u8, short.field, "name"));
    try expect(std.mem.eql(u8, short.rule, "min_len"));

    const old = validate(User{ .name = "methuselah", .age = 200 }).?;
    try expect(std.mem.eql(u8, old.field, "age"));
    try expect(std.mem.eql(u8, old.rule, "max"));
}

test "a schema without rules is fine" {
    const Point = struct { x: f32, y: f32 };
    try expect(validate(Point{ .x = 1, .y = 2 }) == null);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`07-building-libraries.validation-rules`)*

## Errors occur in the correct build

The compiler finds two mistakes when the caller builds. The library author
does no work for this:

- A rule for a field that does not exist: `@field(value, "nmae")` cannot resolve.
- A `min_len` rule on an integer field: `v.len` does not exist on `u8`.

For this reason, use declarations and not registration functions. A call to
`registerValidator("name", ...)` at runtime can fail only at runtime. The
compiler analyzes a declaration against the schema while it has both open.

## The standard library does the same thing

This pattern did not start in the ORM. `std.json` looks for `jsonStringify` on
your type. The format functions look for a `format` declaration.

When your library uses the same shape (a documented declaration name, found
with `@hasDecl`), Zig users already know how to use the library.

## In a full ORM

This page comes from a draft. The draft runs validation inside insert and
update, and returns a typed error set with the violation attached.

The draft also adds rules across fields, for example unique-together and
conditional requirements. These rules are declarations that use the same
discovery pattern. The core stays the twenty lines on this page. The extra
features are more rules.
