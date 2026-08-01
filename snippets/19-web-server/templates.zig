//! title: A Template Engine
//! Substitution is the easy half. Escaping by default is the half that matters.

const std = @import("std");

pub const Binding = struct { name: []const u8, value: []const u8 };

/// The five characters that can end an HTML text node or an attribute value.
/// Escaping is not about being tidy: it is the difference between a name being
/// displayed and a name being executed.
fn writeEscaped(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            '\'' => try out.writeAll("&#39;"),
            else => try out.writeByte(c),
        }
    }
}

fn lookup(bindings: []const Binding, name: []const u8) ?[]const u8 {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return b.value;
    }
    return null;
}

/// `{{name}}` is escaped. `{{{name}}}` is not, and needing three braces to
/// turn escaping off is the entire design: the safe thing is what you get by
/// typing less, and the dangerous thing is visible in a diff.
pub fn render(template: []const u8, bindings: []const Binding, out: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const raw = i + 2 < template.len and template[i + 2] == '{';
            const open = i + if (raw) @as(usize, 3) else 2;
            const close_tag: []const u8 = if (raw) "}}}" else "}}";

            const close = std.mem.find(u8, template[open..], close_tag) orelse {
                // An unterminated placeholder is a typo, and printing it back
                // is more useful than swallowing the rest of the page.
                try out.writeAll(template[i..]);
                return;
            };

            const name = std.mem.trim(u8, template[open .. open + close], " ");
            if (lookup(bindings, name)) |value| {
                if (raw) try out.writeAll(value) else try writeEscaped(out, value);
            } else {
                // A missing binding is not an empty string. Saying so beats a
                // page that silently renders a blank where a price should be.
                try out.print("[missing:{s}]", .{name});
            }
            i = open + close + close_tag.len;
        } else {
            try out.writeByte(template[i]);
            i += 1;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const bindings = [_]Binding{
        .{ .name = "title", .value = "Guest book" },
        .{ .name = "name", .value = "<script>alert('xss')</script>" },
        .{ .name = "note", .value = "Tom & Jerry \"quoted\"" },
        .{ .name = "banner", .value = "<em>welcome</em>" },
    };

    const template =
        \\<h1>{{title}}</h1>
        \\<p>from {{ name }}</p>
        \\<p>{{note}}</p>
        \\<div>{{{banner}}}</div>
        \\<p>{{absent}}</p>
        \\<p>{{unclosed
    ;

    try render(template, &bindings, out);
    try out.writeAll("\n");
    try out.flush();
}
