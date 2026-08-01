//! title: A Scripting Engine
//! The language knows nothing about documents. The host is what connects them.

const std = @import("std");
const dom = @import("html.zig");

/// The smallest evaluator that can show the binding: names, integers, `+`,
/// `<` and `print`. The real language is the one built in the Tiny Language
/// section, with a lexer, a parser, an interpreter and a bytecode VM. It is
/// not imported here because each snippet on this site compiles on its own,
/// and in a browser the two are separate libraries linked together anyway.
///
/// What matters is the seam, and the seam is `Env`.
const Env = struct {
    names: [8][]const u8 = undefined,
    values: [8]i64 = undefined,
    count: usize = 0,

    fn define(e: *Env, name: []const u8, value: i64) !void {
        if (e.count == e.names.len) return error.Full;
        e.names[e.count] = name;
        e.values[e.count] = value;
        e.count += 1;
    }

    fn get(e: Env, name: []const u8) !i64 {
        for (e.names[0..e.count], 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return e.values[i];
        }
        return error.UndefinedVariable;
    }
};

/// `print <expr>;` where an expression is a chain of names and numbers joined
/// by `+`. Enough to demonstrate that a script reads host-provided values and
/// nothing more.
fn eval(env: Env, expr: []const u8) !i64 {
    var total: i64 = 0;
    var terms = std.mem.tokenizeAny(u8, expr, "+ \t");
    while (terms.next()) |term| {
        total += std.fmt.parseInt(i64, term, 10) catch try env.get(term);
    }
    return total;
}

fn run(env: Env, script: []const u8, out: *std.Io.Writer) !void {
    var lines = std.mem.tokenizeAny(u8, script, ";\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "print ")) return error.Unsupported;
        try out.print("  {d}\n", .{try eval(env, line["print ".len..])});
    }
}

/// Count the elements with a given tag, anywhere in the tree.
fn countTag(nodes: []const dom.Node, index: u32, tag: []const u8) u32 {
    var total: u32 = 0;
    const node = nodes[index];
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, tag)) total += 1;
    var child = node.first;
    while (child) |c| : (child = nodes[c].next) total += countTag(nodes, c, tag);
    return total;
}

/// The bridge. The evaluator has no idea what an element is; the host walks
/// the document and defines ordinary variables. Everything the script can see
/// about the page is what was put here, which is exactly what a "host object"
/// means: not part of the language, installed by whatever is embedding it.
fn bind(env: *Env, nodes: []const dom.Node, root: u32) !void {
    try env.define("paragraphs", countTag(nodes, root, "p"));
    try env.define("headings", countTag(nodes, root, "h1"));
    try env.define("images", countTag(nodes, root, "img"));
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const html =
        \\<h1>Gallery</h1>
        \\<p>One</p>
        \\<p>Two</p>
        \\<p>Three</p>
        \\<img src=a.png>
        \\<img src=b.png>
    ;

    var doc: [32]dom.Node = undefined;
    const tree = try dom.parseInto(html, &doc);

    var env: Env = .{};
    try bind(&env, &doc, tree.root);

    try out.writeAll("what the host put in scope\n");
    for ([_][]const u8{ "paragraphs", "headings", "images" }) |name| {
        try out.print("  {s: <11} {d}\n", .{ name, try env.get(name) });
    }

    // The script has no syntax for documents and needs none. `paragraphs` is
    // an ordinary variable that happens to have been set by walking a tree.
    const script =
        \\print paragraphs;
        \\print paragraphs + images;
        \\print headings + paragraphs + images;
    ;

    try out.writeAll("\nwhat the script printed\n");
    try run(env, script, out);

    // A name the host never defined is an ordinary undefined variable. There
    // is no separate category of "DOM error".
    try out.writeAll("\nasking for something not in scope\n");
    if (run(env, "print stylesheets;", out)) |_| {
        try out.writeAll("  accepted, which is wrong\n");
    } else |err| {
        try out.print("  {t}\n", .{err});
    }

    try out.flush();
}
