//! title: JSON
//! Parsing into real types, and serialising back out.

const std = @import("std");
const expect = std.testing.expect;

const Config = struct {
    name: []const u8,
    port: u16,
    debug: bool = false, // defaults cover missing fields
};

test "parse into a struct" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "name": "server", "port": 8080 }
    ;

    // The parse result owns its allocations; deinit frees them all at once.
    const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    defer parsed.deinit();

    try expect(std.mem.eql(u8, parsed.value.name, "server"));
    try expect(parsed.value.port == 8080);
    try expect(parsed.value.debug == false);
}

test "unknown fields are rejected by default" {
    const gpa = std.testing.allocator;
    const text =
        \\{ "name": "x", "port": 1, "extra": true }
    ;
    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(Config, gpa, text, .{}),
    );

    // Opt out when the payload may carry fields you do not model.
    const lenient = try std.json.parseFromSlice(Config, gpa, text, .{
        .ignore_unknown_fields = true,
    });
    defer lenient.deinit();
    try expect(lenient.value.port == 1);
}

test "dynamic values when the shape is unknown" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{ "a": [1, 2, 3] }
    ,
        .{},
    );
    defer parsed.deinit();

    const array = parsed.value.object.get("a").?.array;
    try expect(array.items.len == 3);
    try expect(array.items[0].integer == 1);
}

test "serialise" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.json.Stringify.value(
        Config{ .name = "out", .port = 99, .debug = true },
        .{},
        &out.writer,
    );
    try expect(std.mem.indexOf(u8, out.written(), "\"port\":99") != null);
}
