# A Scripting Engine

> The language knows nothing about documents. The host makes the connection between them.

Many people think that the DOM is a part of JavaScript. It is not. The JavaScript specification does not mention `document`, `window`, `fetch` or an element.

The specification defines a language: values, functions, objects and control flow. A browser **embeds** that language, and then adds a set of names to its global scope. These names are **host objects**. They are the only connection between a script and a page.

Node has a different set of names. A game engine that embeds a scripting language has a third set. The language is the same in all of them.

## The program

```zig
const std = @import("std");
const dom = @import("html.zig");

/// The smallest evaluator that can show the binding: names, integers, `+`
/// and `print`. The Tiny Language section builds the real language, with a
/// lexer, a parser, an interpreter and a bytecode VM. This file does not
/// import it, because each snippet on this site compiles alone. Also, in a
/// browser, the language and the host are separate libraries.
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

/// `print <expr>;`. An expression is a chain of names and numbers, with `+`
/// between them. That is sufficient to show that a script reads the values
/// from the host and nothing more.
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

/// Count the elements with a given tag, at all levels of the tree.
fn countTag(nodes: []const dom.Node, index: u32, tag: []const u8) u32 {
    var total: u32 = 0;
    const node = nodes[index];
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, tag)) total += 1;
    var child = node.first;
    while (child) |c| : (child = nodes[c].next) total += countTag(nodes, c, tag);
    return total;
}

/// The link between the page and the script. The evaluator does not know
/// what an element is. The host walks the document and defines ordinary
/// variables. About the page, the script sees only the values in this
/// function. That is a "host object": it is not part of the language. The
/// program that embeds the language installs it.
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

    // The script has no syntax for documents, and it needs none. `paragraphs`
    // is an ordinary variable. The host set its value with a walk of a tree.
    const script =
        \\print paragraphs;
        \\print paragraphs + images;
        \\print headings + paragraphs + images;
    ;

    try out.writeAll("\nwhat the script printed\n");
    try run(env, script, out);

    // A name that the host did not define is an ordinary undefined variable.
    // There is no separate category of "DOM error".
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

**The host walked the document and defined three ordinary variables.** `paragraphs` is 3, because a walk through the tree counted three `<p>` elements. For the evaluator, `paragraphs` is a name with an integer value. It looks the same as a variable that the script declared.

**The script has no syntax for documents, and it needs none.** `print paragraphs + images` is arithmetic. No part of the grammar knows what an image is. To give the page a new capability, the host defines one more name. The language does not change.

**A name that the host did not define is an ordinary undefined variable.** The request for `stylesheets` gave `UndefinedVariable`. A typo in a local name gives the same error. There is no separate type of "DOM error". For the same reason, in a real browser, `document.foo is not a function` and `myTypo is not defined` come from the same code.

**The evaluator here is intentionally very small.** It supports names, integers, `+` and `print`. That is sufficient to show where the language and the host meet.

[The Tiny Language section](https://www.ziglang.in/learn/tiny-lang/lexer/) builds a fuller language, with a lexer, a parser, a tree-walking interpreter and a bytecode VM. In a browser, the language and the host are two separate libraries, and the build links them together, as in this program. V8 does not contain a DOM. Chrome supplies the DOM.

## What a real binding adds

**Writes, not only reads.** A script that can only read the page cannot do much. `element.textContent = "x"` changes the tree. Then layout and paint run again, with the two passes from [the layout chapter](https://www.ziglang.in/learn/browser/layout/).

**Objects instead of flat names.** A real script uses `document.querySelectorAll("p").length` instead of `paragraphs`. For that, the language must have objects, and the host must put functions on those objects. That is more code, but the idea is the same.

**Events.** In the program above, nothing runs two times. A real engine keeps the environment alive. It calls back into the environment when an event occurs. Thus the variables of the script live longer than the script.

Then the host has a problem with lifetimes. A listener that holds a reference to a removed element keeps that element alive. This is a common memory leak on the web. It occurs because the language and the host both hold objects that point to each other.

## Check yourself

The language does not know what an element is. Then how does a script get a *type error* when it calls a method on the wrong thing?

For the language, host objects are ordinary objects. A script can call a method that does not exist on a host object. That call fails in the same way as on any other object.

The engine does not know that `document` is special. It knows only two facts. The thing with the name `document` has no property `queryselectorAll`, because you misspelled `querySelectorAll`. And a call to `undefined` is an error.

Thus these error messages usually tell you little about your mistake. The engine that reports them does not know what a document is.

Next: [the whole pipeline](https://www.ziglang.in/learn/browser/browser/), with each stage in one program.
