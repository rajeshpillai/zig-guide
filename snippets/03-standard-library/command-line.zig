//! title: Command-Line Arguments
//! Read argv and the environment through std.process.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "iterate arguments" {
    const gpa = std.testing.allocator;
    // A real program iterates over `init.minimal.args` (see the page). This
    // test parses a fixed command line with the same iterator. Thus the test
    // gives the same result in the browser sandbox, which has no argv.
    var it = try std.process.Args.IteratorGeneral(.{}).init(gpa, "app --name zig -v");
    defer it.deinit();

    try expectEqualStrings("app", it.next().?); // argv[0] is the program name
    try expectEqualStrings("--name", it.next().?);
    try expectEqualStrings("zig", it.next().?);
    try expectEqualStrings("-v", it.next().?);
    try expect(it.next() == null); // no more arguments
}

test "a minimal flag parser" {
    const gpa = std.testing.allocator;
    var it = try std.process.Args.IteratorGeneral(.{}).init(gpa, "app --verbose --out result.txt");
    defer it.deinit();

    _ = it.next(); // skip argv[0]
    var verbose = false;
    var out: []const u8 = "a.out";
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            // A flag that takes a value gets the next token itself.
            out = it.next() orelse return error.MissingValue;
        }
    }
    try expect(verbose);
    try expectEqualStrings("result.txt", out);
}

test "environment variables" {
    const gpa = std.testing.allocator;
    // `init.environ_map` has exactly this type, and the real environment
    // fills it. This test makes the map by hand. Thus the test needs nothing
    // from outside.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("EDITOR", "vim");

    try expectEqualStrings("vim", env.get("EDITOR").?);
    try expect(env.get("MISSING") == null);
    try expect(env.contains("EDITOR"));
}
