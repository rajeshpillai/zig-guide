# A Template Engine

> Substitution is the easy half. Escaping by default is the half that matters.

So far every response has been a string literal in Zig source. That stops
working immediately. HTML wants to be edited by someone who is not
recompiling, and a page assembled by concatenation is a page where the markup
and the data are the same kind of thing.

A template engine separates them. Read a file with holes in it, fill the
holes, send the result. The filling is a substring search and takes an
afternoon.

The half that matters is what happens when the value contains `<`.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`19-web-server.templates`)*

## What just happened

**The script tag came out inert.** The binding for `name` was
`<script>alert('xss')</script>`, and what reached the page was
`&lt;script&gt;...`, which a browser displays as text. That is the difference
between a guest book and a guest book that runs anybody's JavaScript in every
visitor's session, which is precisely the session cookie from the last
chapter.

**Escaping is the default and unescaping takes more typing.** `{{name}}` is
escaped; `{{{banner}}}` is not. Requiring an extra brace to turn safety off is
the whole design, and it is worth stating why. The safe thing is what you get
by typing less. The dangerous thing is three characters that stand out in a
code review. Every template engine that made escaping opt-*in* has a CVE list.

**All five characters are escaped, not three.** `&`, `<` and `>` are the
obvious ones. They matter because a value is not always in a text node. An
attribute is a different context, where a quote ends the attribute and
everything after it is markup. An escaper that handles only the first three is
safe in one context and broken in the other.

**A missing binding printed `[missing:absent]`.** Not an empty string. A blank where a price should be is a bug that reaches production, because it
looks like a design choice. A visible marker is found the first time anyone
looks at the page.

**The unterminated `{{unclosed` was printed back verbatim.** It is a typo in
the template, and showing it is more useful than swallowing the rest of the
page trying to find a `}}` that is not there.

## Check yourself

The escaper is correct for HTML text and attributes. Where is it wrong?

Inside a `<script>` block and inside a URL. `<a href="{{link}}">` with a value
of `javascript:alert(1)` is escaped perfectly and still executes, because the
characters were never the problem there: the *scheme* is. And a value
substituted into JavaScript needs JavaScript escaping, where `</script>`
inside a string literal ends the block regardless of how the quotes are
handled.

This is why real engines are **context-aware**. They parse enough of the HTML
to know whether a hole sits in text, an attribute, a URL or a script, and
apply a different escaper to each. Go's `html/template` does this and is the
standard reference for it. A single escaper is a large improvement over none
and is not the finish line.

## If you have written C

Substitution in C is a loop with a search and a lot of pointer arithmetic to
decide how much to copy between holes. It is one of the more pleasant things
to write in the language, because everything is a length and an offset.

The escaping is where it gets unpleasant, and the reason is sizing. The
escaped form of a string is longer than the input, by up to six times if it is
all apostrophes, so the output buffer cannot be the input's length. You either
compute the size in a first pass, grow as you go, or write straight to the
socket. The version above writes to the writer directly, which sidesteps the
question entirely and is usually the right answer: the escaped text never
needs to exist as a whole.

## Where this section stands

Seven chapters. Parse a request. Answer over a socket. Serve a file without
handing out the whole disk. Route. Read a form. Remember who is asking. And
render a page without executing what they typed.

That is a small web server, and the parts of it that are not here are mostly
scale rather than concept: keep-alive, chunked bodies, compression, TLS, and
concurrency, which [many clients](https://www.ziglang.in/learn/networking/many-clients/) covers.
File uploads have their own chapter, [File
Uploads](https://www.ziglang.in/learn/web-server/multipart/), because `multipart/form-data` is a
second body format rather than a variation on the first.
