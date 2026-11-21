# A Template Engine

> Substitution is the easy half. Escaping by default is the more difficult half.

Until now, each response was a string literal in Zig source. That method does
not work for long. People must edit HTML without a new compile. Also, when a
program makes a page from joined strings, the markup and the data are the same
type of thing.

A template engine keeps the markup and the data separate. The engine reads a
file with holes in it, fills the holes, and sends the result. To fill the holes
is a substring search, and you can write that code in an afternoon.

The important part is what occurs when the value contains `<`.

## The program

```zig
const std = @import("std");

pub const Binding = struct { name: []const u8, value: []const u8 };

/// The five characters that can end an HTML text node or an attribute value.
/// Escaping decides if the browser shows a name or runs it.
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

/// The engine escapes `{{name}}`, but not `{{{name}}}`. To turn off escaping,
/// you need three braces. Thus the safe form is shorter to type, and the
/// dangerous form is easy to see in a diff.
pub fn render(template: []const u8, bindings: []const Binding, out: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const raw = i + 2 < template.len and template[i + 2] == '{';
            const open = i + if (raw) @as(usize, 3) else 2;
            const close_tag: []const u8 = if (raw) "}}}" else "}}";

            const close = std.mem.find(u8, template[open..], close_tag) orelse {
                // An unterminated placeholder is a typo. It is more useful to
                // print the typo than to hide the rest of the page.
                try out.writeAll(template[i..]);
                return;
            };

            const name = std.mem.trim(u8, template[open .. open + close], " ");
            if (lookup(bindings, name)) |value| {
                if (raw) try out.writeAll(value) else try writeEscaped(out, value);
            } else {
                // A binding that does not exist is not an empty string. A marker is
                // better than a page that silently shows a blank in the place
                // of a price.
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

## What the program did

**The script tag became harmless.** The binding for `name` was
`<script>alert('xss')</script>`, and the page got `&lt;script&gt;...`. A
browser shows that text as text. Without escaping, a guest book runs the
JavaScript of any person in the session of each visitor. That script can then
use the session cookie from the last chapter.

**Escaping is the default. To stop escaping, you must type more.** The engine
escapes `{{name}}`, and it does not escape `{{{banner}}}`. You need an extra
brace to turn off escaping. Thus the safe form is shorter to type.

The dangerous
form uses three braces, and three braces are easy to see in a code review.
Template engines that made escaping opt-*in* all have lists of security
vulnerabilities (CVEs).

**The engine escapes five characters, not three.** `&`, `<` and `>` are the
obvious ones. The two quote characters are important because a value is not
always in a text node. An attribute is a different context. In an attribute, a
quote ends the attribute, and all text after the quote is markup. An escaper
that handles only the first three characters is safe in one context and broken
in the other context.

**A binding that does not exist printed `[missing:absent]`, not an empty string.** Suppose
a page shows a blank in the place of a price. That bug gets into production,
because the blank looks like a design choice. A person sees a visible marker
the first time that they look at the page.

**The engine printed the unterminated `{{unclosed` without a change.** The text
is a typo in the template. It is more useful to show the typo than to hide the
rest of the page. If the engine hides the page, it searches for a `}}` that
does not exist.

## Check yourself

The escaper is correct for HTML text and for quoted attribute values. Where is
the escaper incorrect?

The answer: inside a `<script>` block and inside a URL.

- `<a href="{{link}}">` with the value `javascript:alert(1)` has correct
  escaping, and the script still runs. In a URL, the problem is the *scheme*,
  not the characters.
- A value in JavaScript needs JavaScript escaping. Inside a string literal,
  `</script>` ends the block, and the quotes have no effect on that.
- The escaper is also incorrect in an unquoted attribute. In
  `<a href={{link}}>`, the value ends at the first space. Thus a value such as
  `x onmouseover=alert(1)` becomes new markup, and it uses none of the five
  escaped characters.

Thus production engines are **context-aware**. They parse enough of the HTML to
know if a hole is in text, an attribute, a URL or a script. Then they use a
different escaper for each context. The Go `html/template` package does this,
and it is the standard reference. A single escaper is much better than no
escaper, but it is not sufficient alone.

## If you know C

Substitution in C is a loop with a search. The loop uses much pointer
arithmetic to calculate how much to copy between holes. This code is one of the
easier things to write in C, because all values are a length and an offset.

The escaping is more difficult, because of the size. The escaped string is
longer than the input. If the input is all double quotes, the escaped string is
six times longer, because `&quot;` is six characters. Thus the output buffer
cannot have the length of the input. You have three choices:

- Calculate the size in a first pass.
- Make the buffer larger while you write.
- Write directly to the socket.

The version above writes directly to the writer. Thus it never needs to know
the size. Usually that is the correct choice, because the full escaped text is
never necessary in memory.

## The state of this section

The seven chapters until now do these tasks:

- Parse a request.
- Answer over a socket.
- Serve files, and keep the rest of the disk safe.
- Route.
- Read forms.
- Remember users.
- Render pages, and do not run the text that users typed.

Together, the chapters make a small web server.

The parts that are not in this section are mostly about scale, not about new ideas: keep-alive,
chunked bodies, compression, TLS, and concurrency.
[Many clients](https://www.ziglang.in/learn/networking/many-clients/) shows concurrency. File
uploads have their own chapter, [File Uploads](https://www.ziglang.in/learn/web-server/multipart/),
because `multipart/form-data` is a second body format. It is not a variation of
the first format.
