//! title: A Custom JSON Serializer
//! A jsonStringify method renames fields and adds computed ones.

const std = @import("std");

// Identical fields, no hook: this is what the default serializer emits.
const Plain = struct {
    id: u64,
    name: []const u8,
    is_admin: bool,
    created_at: i64,
};

const User = struct {
    id: u64,
    name: []const u8,
    is_admin: bool,
    created_at: i64,

    // When present, std.json.Stringify calls this instead of walking the
    // fields. `jws` is a *std.json.Stringify write stream. It balances
    // begin/end and quotes strings for you, so the output is always valid.
    pub fn jsonStringify(self: User, jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("user_id"); // rename id
        try jws.write(self.id);

        try jws.objectField("full_name"); // rename name
        try jws.write(self.name);

        try jws.objectField("admin"); // rename is_admin
        try jws.write(self.is_admin);

        // A computed field the struct does not store: whole days since epoch.
        try jws.objectField("epoch_day");
        try jws.write(@divTrunc(self.created_at, std.time.s_per_day));

        try jws.endObject();
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const id = 101;
    const name = "Ziggy Stardust";
    const admin = true;
    const ts = 1672531200; // 2023-01-01T00:00:00Z

    try out.writeAll("default: ");
    try std.json.Stringify.value(
        Plain{ .id = id, .name = name, .is_admin = admin, .created_at = ts },
        .{},
        out,
    );
    try out.writeAll("\n");

    try out.writeAll("custom:  ");
    try std.json.Stringify.value(
        User{ .id = id, .name = name, .is_admin = admin, .created_at = ts },
        .{},
        out,
    );
    try out.writeAll("\n");

    try out.flush();
}
