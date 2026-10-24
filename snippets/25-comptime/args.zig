//! title: "Project: Parse Arguments from a Struct"
//! The fields of a struct are the options. The compiler writes the parser.

const std = @import("std");

const Level = enum { debug, info, warn };

// Each field is one option. A field with a default is optional.
const Options = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
    verbose: bool = false,
    level: Level = .info,
    name: []const u8,
};

const ParseError = error{ UnknownOption, MissingValue, BadValue, MissingOption };

fn parseValue(comptime T: type, text: []const u8) ParseError!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch error.BadValue,
        .@"enum" => std.meta.stringToEnum(T, text) orelse error.BadValue,
        .pointer => if (T == []const u8) text else @compileError("unsupported option type " ++ @typeName(T)),
        else => @compileError("unsupported option type " ++ @typeName(T)),
    };
}

fn parse(comptime T: type, args: []const []const u8) ParseError!T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    // One flag for each field: did an argument set it?
    var seen: [info.field_names.len]bool = @splat(false);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        const key = arg[2..];
        var known = false;
        // The compiler unrolls this loop: one `if` for each field.
        inline for (info.field_names, info.field_types, 0..) |name, F, f| {
            if (std.mem.eql(u8, key, name)) {
                known = true;
                seen[f] = true;
                if (F == bool) {
                    @field(result, name) = true;
                } else {
                    i += 1;
                    if (i == args.len) return error.MissingValue;
                    @field(result, name) = try parseValue(F, args[i]);
                }
            }
        }
        if (!known) return error.UnknownOption;
    }

    // A field that no argument set gets its default, or is an error.
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, f| {
        if (!seen[f]) {
            @field(result, name) = attrs.defaultValue(F) orelse return error.MissingOption;
        }
    }
    return result;
}

// The help text, made during compilation from the same struct.
fn help(comptime T: type) []const u8 {
    comptime var text: []const u8 = "options:\n";
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const kind = switch (@typeInfo(F)) {
            .bool => "",
            .@"enum" => |e| blk: {
                var choices: []const u8 = "";
                for (e.field_names, 0..) |choice, c| choices = choices ++ (if (c == 0) "" else "|") ++ choice;
                break :blk " <" ++ choices ++ ">";
            },
            else => if (F == []const u8) " <text>" else " <" ++ @typeName(F) ++ ">",
        };
        const required = if (attrs.defaultValue(F) == null) " (required)" else "";
        text = text ++ "  --" ++ name ++ kind ++ required ++ "\n";
    }
    return text;
}

fn show(out: *std.Io.Writer, args: []const []const u8) !void {
    try out.print("args:", .{});
    for (args) |arg| try out.print(" {s}", .{arg});
    try out.print("\n", .{});
    if (parse(Options, args)) |o| {
        try out.print("  port={d} host={s} verbose={} level={t} name={s}\n", .{ o.port, o.host, o.verbose, o.level, o.name });
    } else |err| {
        try out.print("  error: {t}\n", .{err});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("{s}", .{comptime help(Options)});
    try show(out, &.{ "--name", "api" });
    try show(out, &.{ "--name", "api", "--port", "9090", "--verbose", "--level", "debug" });
    try show(out, &.{"--port"});
    try show(out, &.{ "--port", "99999", "--name", "x" });
    try show(out, &.{ "--level", "loud", "--name", "x" });
    try show(out, &.{ "--colour", "red" });
    try show(out, &.{"--verbose"});
}
