//! title: Validation from Declarations
//! Optional per-schema rules, discovered with @hasDecl, checked in one pass.

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
