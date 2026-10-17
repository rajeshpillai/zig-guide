# A Scripting Engine

> The language knows nothing about documents. The host is what connects them.

Many people think the DOM is part of JavaScript. It is not. The JavaScript
specification never mentions `document`, `window`, `fetch` or an element.

The specification defines a language: values, functions, objects and
control flow. A browser **embeds** that language and then adds a set of names
to its global scope. Those names are **host objects**. They are the only
connection between a script and a page.

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
/// The script and the page meet in one place: `Env`.
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
/// by `+`. Enough to show that a script reads host-provided values and
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

/// The link between page and script. The evaluator does not know what an
/// element is. The host walks the document and defines ordinary variables.
/// The script can see only what was put here about the page. That is what a
/// "host object" means: it is not part of the language, and it is installed
/// by whatever program embeds the language.
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
evaluator it is a name with an integer behind it. It looks exactly like a
variable the script declared itself.

**The script has no syntax for documents, and needs none.** `print paragraphs +
images` is arithmetic. Nothing in the grammar knows what an image is. To give
the page a new capability, the host defines another name. The language does
not change.

**A name the host never defined is an ordinary undefined variable.** Asking for
`stylesheets` produced `UndefinedVariable`, the same error a typo in a local
name would produce. There is no separate kind of "DOM error". For the same
reason, `document.foo is not a function` and `myTypo is not defined` come from
the same code in a real browser.

**The evaluator here is deliberately tiny.** It handles names, integers, `+`
and `print`. That is enough to show where the language and the host meet.
A fuller language is built in [the Tiny Language section](https://www.ziglang.in/learn/tiny-lang/lexer/),
with a lexer, a parser, a tree-walking interpreter and a bytecode VM. In a
browser the two are separate libraries linked together, as in this program.
V8 does not contain a DOM. Chrome supplies one.

## What a real binding adds

**Writing, not just reading.** A script that can only read the page cannot do
much. `element.textContent = "x"` changes the tree, so layout and paint run
again, repeating the two passes from [the layout chapter](https://www.ziglang.in/learn/browser/layout/).

**Objects rather than flat names.** `document.querySelectorAll("p").length`
instead of `paragraphs`. That needs the language to have objects and the host
to expose functions on them. That is more code, but the idea is the same.

**Events.** Nothing above ever runs twice. A real engine keeps the environment alive and calls back into it when
something happens, so the script's variables outlive the script. Now the host
has a lifetime problem. A listener that holds a reference to a removed element
keeps that element alive. This is a common memory leak on the web. It happens
because both the language and the host hold objects that point at each other.

## Check yourself

If the language has no idea what an element is, how does a script get a *type
error* when it calls a method on the wrong thing?

Because host objects are ordinary objects as far as the language is concerned.
Calling a missing method on one fails the same way calling a missing method on
any object fails. The engine does not know that `document` is special. It
only knows that the thing named `document` has no property called
`queryselectorAll`, because you misspelled `querySelectorAll`, and that calling
`undefined` is an error.

So these error messages usually say little about what you did wrong. The
engine that reports them has no idea what a document is.

Next: [the whole pipeline](https://www.ziglang.in/learn/browser/browser/), with every stage in one
program.
