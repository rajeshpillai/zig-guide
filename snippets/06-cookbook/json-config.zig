//! title: Load a JSON Config
//! Defaults for absent fields, and validation for wrong values.

const std = @import("std");

const Config = struct {
    // Each field has a default. Thus an empty `{}` is a valid config.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    workers: u8 = 4,
    debug: bool = false,
};

// The parser checks the shape (types, field names). You must check the values.
fn validate(c: Config) error{ PrivilegedPort, TooManyWorkers }!void {
    if (c.port < 1024) return error.PrivilegedPort;
    if (c.workers == 0 or c.workers > 64) return error.TooManyWorkers;
}

fn load(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(Config) {
    const parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    // If validation refuses the config, the config must not leak.
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn report(out: *std.Io.Writer, gpa: std.mem.Allocator, text: []const u8) !void {
    const parsed = load(gpa, text) catch |err| {
        try out.print("rejected: {t}\n", .{err});
        return;
    };
    defer parsed.deinit();
    const c = parsed.value;
    try out.print("loaded:   host={s} port={d} workers={d} debug={}\n", .{
        c.host, c.port, c.workers, c.debug,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;

    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Partial input: absent fields get their defaults.
    try report(out, gpa,
        \\{ "host": "0.0.0.0", "port": 9000 }
    );

    // Empty input: all fields get their defaults.
    try report(out, gpa, "{}");

    // Valid JSON with a bad value: validate finds the error, not the parser.
    try report(out, gpa,
        \\{ "port": 80 }
    );

    // By default, a field name with a spelling error is an error. It finds a
    // config that is different from the config that the user *wanted*.
    try report(out, gpa,
        \\{ "prot": 9000 }
    );

    // The text is not JSON.
    try report(out, gpa, "port = 9000");

    try out.flush();
}
