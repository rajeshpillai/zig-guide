//! title: Command-Line Arguments
//! Reading argv and the environment through std.process.

const std = @import("std");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "iterate arguments" {
    const gpa = std.testing.allocator;
    // A real program iterates `init.minimal.args` (see the page). Here we
    // parse a fixed command line with the same iterator, so the test stays
    // deterministic in the browser sandbox, which has no argv of its own.
    var it = try std.process.Args.IteratorGeneral(.{}).init(gpa, "app --name zig -v");
    defer it.deinit();

    try expectEqualStrings("app", it.next().?); // argv[0] is the program name
    try expectEqualStrings("--name", it.next().?);
    try expectEqualStrings("zig", it.next().?);
    try expectEqualStrings("-v", it.next().?);
    try expect(it.next() == null); // exhausted
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
            // A flag that takes a value pulls the next token itself.
            out = it.next() orelse return error.MissingValue;
        }
    }
    try expect(verbose);
    try expectEqualStrings("result.txt", out);
}

test "environment variables" {
    const gpa = std.testing.allocator;
    // `init.environ_map` is exactly this type, filled from the real
    // environment. Building one by hand keeps the test self-contained.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("EDITOR", "vim");

    try expectEqualStrings("vim", env.get("EDITOR").?);
    try expect(env.get("MISSING") == null);
    try expect(env.contains("EDITOR"));
}
