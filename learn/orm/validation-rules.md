# Validation from Declarations

> Optional capabilities discovered with @hasDecl, the convention-over-configuration of Zig.

## The problem

Your library wants optional, per-type behavior: validation rules on one
schema, custom serialization on another, nothing on a third. Interfaces and
inheritance are the classical answers; Zig has neither. What it has is better
suited to libraries: the caller *declares* what they support, and the library
*asks*, at compile time.

## The pattern

1. The convention: a schema may declare `pub const rules = .{ ... }`,
   naming its own fields.
2. The library checks `@hasDecl(T, "rules")` before touching it. No
   declaration means no validation and zero generated code.
3. `inline for` walks the rules; `@hasField` on each rule struct decides
   which checks apply. Every lookup resolves while compiling; the runtime
   work is just the comparisons themselves.

```zig
const std = @import("std");
const expect = std.testing.expect;

const Violation = struct {
    field: []const u8,
    rule: []const u8,
};

// The library-side half: walk the value's fields; when the schema declares
// a rule for a field, apply it. Schemas without rules validate trivially,
// and unknown rule names fail the build rather than being ignored.
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

// The caller-side half: rules live on the schema as one declaration,
// naming fields directly. A rule for a field that does not exist fails
// to compile, because @field(value, ...) has nothing to resolve to.
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

## Errors land at the right build

Two mistakes are caught at the caller's compile, with no effort from the
library author:

- A rule for a nonexistent field: `@field(value, "nmae")` cannot resolve.
- A `min_len` rule on an integer field: `v.len` does not exist on `u8`.

This is the deep reason to prefer declarations over registration functions. A
runtime `registerValidator("name", ...)` call can only fail at runtime; a
declaration is analyzed against the schema while both are open in the
compiler.

## The standard library does the same thing

This is not an ORM invention. `std.json` looks for `jsonStringify` on your
type; formatting looks for a `format` declaration. When your library adopts
the same shape (a documented declaration name, discovered with `@hasDecl`),
Zig users already know how to hold it.

## In a full ORM

The draft this distills from runs validation inside insert and update,
returning a typed error set with the violation attached. It also adds
cross-field rules, such as unique-together and conditional requirements, as
declarations following the same discovery pattern. The skeleton stays this
page's twenty lines; everything else is more rules.
