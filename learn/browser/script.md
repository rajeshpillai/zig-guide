# A Scripting Engine

> The language knows nothing about documents. The host is what connects them.

The most common misconception about JavaScript in a browser is that the DOM is
part of the language. It is not, and nothing in the JavaScript specification
mentions `document`, `window`, `fetch` or an element.

What the specification defines is a language: values, functions, objects,
control flow. What a browser does is **embed** that language and then install
a set of names into its global scope. Those names are **host objects**, and
they are the entire connection between a script and a page.

Node has a different set. A game engine embedding a scripting language has a
third. The language is the same in all of them.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.script`)*

## What just happened

**The host walked the document and defined three ordinary variables.**
`paragraphs` is 3 because a tree walk counted three `<p>` elements. To the
evaluator it is a name with an integer behind it, indistinguishable from one
the script declared itself.

**The script has no syntax for documents, and needs none.** `print paragraphs +
images` is arithmetic. Nothing in the grammar knows what an image is, and
adding a new capability to the page means the host defining another name, not
the language growing a feature.

**A name the host never defined is an ordinary undefined variable.** Asking for
`stylesheets` produced `UndefinedVariable`, the same error a typo in a local
name would produce. There is no separate category of "DOM error", which is why
`document.foo is not a function` and `myTypo is not defined` come from the
same machinery in a real browser.

**The evaluator here is deliberately tiny.** It handles names, integers, `+`
and `print`, and that is all it needs to show the seam. The real language is
the one built in [the Tiny Language section](https://www.ziglang.in/learn/tiny-lang/lexer/), with a
lexer, a parser, a tree-walking interpreter and a bytecode VM. In a browser
the two are separate libraries linked together, which is exactly the
relationship being demonstrated: V8 does not contain a DOM, and Chrome
supplies one.

## What a real binding adds

**Writing, not just reading.** A script that can only observe the page is a
curiosity. `element.textContent = "x"` changes the tree, which invalidates the
boxes, which means layout runs again and then painting runs again. That is the
whole cost model of a dynamic page, and it is why the [layout
chapter's](https://www.ziglang.in/learn/browser/layout/) two passes matter so much: they are the
thing being repeated.

**Objects rather than flat names.** `document.querySelectorAll("p").length`
instead of `paragraphs`. That needs the language to have objects and the host
to expose functions on them, which is more plumbing and the same idea.

**Events.** Nothing above ever runs twice. A real engine keeps the environment alive and calls back into it when
something happens, so the script's variables outlive the script. Now the host
has a lifetime problem: a listener holding a reference to a removed element
keeps it alive. That is the most common memory leak on the web, and it exists
because the seam has objects on both sides of it.

## Check yourself

If the language has no idea what an element is, how does a script get a *type
error* when it calls a method on the wrong thing?

Because host objects are ordinary objects as far as the language is concerned.
Calling a missing method on one fails the same way calling a missing method on
any object fails. The engine does not know that `document` is special; it
knows that the thing named `document` has no property called
`queryselectorAll` and that calling `undefined` is an error.

This is why the error messages are usually so unhelpful about what you
actually did wrong. The engine reporting them has no concept of a document to
explain.

Next: [the whole pipeline](https://www.ziglang.in/learn/browser/browser/), with every stage in one
program.
