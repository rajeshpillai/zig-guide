# A Template Engine

> Substitution is the easy half. Escaping by default is the harder half.

So far every response has been a string literal in Zig source. That does not
work for long. People need to edit HTML without recompiling. And when a page is
built by joining strings, the markup and the data are the same kind of thing.

A template engine keeps them apart. It reads a file with holes in it, fills
the holes, and sends the result. The filling is a substring search and takes
an afternoon to write.

The important part is what happens when the value contains `<`.

## The program

```zig
const std = @import("std");

pub const Binding = struct { name: []const u8, value: []const u8 };

/// The five characters that can end an HTML text node or an attribute value.
/// Escaping decides whether a name is displayed or executed.
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

/// `{{name}}` is escaped. `{{{name}}}` is not. Turning escaping off needs
/// three braces, so the safe form is the shorter one to type, and the
/// dangerous form is easy to see in a diff.
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
                // A missing binding is not an empty string. Printing a marker
                // is better than a page that silently shows a blank where a
                // price should be.
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
`&lt;script&gt;...`, which a browser displays as text. Without escaping, a
guest book would run anybody's JavaScript in every visitor's session. That
script could then use the session cookie from the last chapter.

**Escaping is the default and unescaping takes more typing.** `{{name}}` is
escaped; `{{{banner}}}` is not. You need an extra brace to turn escaping off.
So the safe form is the one with less typing. The dangerous form uses three
braces, which stand out in a code review. Template engines that made escaping
opt-*in* all have lists of security vulnerabilities (CVEs).

**All five characters are escaped, not three.** `&`, `<` and `>` are the
obvious ones. They matter because a value is not always in a text node. An
attribute is a different context, where a quote ends the attribute and
everything after it is markup. An escaper that handles only the first three is
safe in one context and broken in the other.

**A missing binding printed `[missing:absent]`, not an empty string.** A blank
where a price should be is a bug that reaches production, because it looks like
a design choice. A visible marker is found the first time anyone looks at the
page.

**The unterminated `{{unclosed` was printed back as it was.** It is a typo in
the template. Showing it is more useful than hiding the rest of the page while
looking for a `}}` that is not there.

## Check yourself

The escaper is correct for HTML text and for quoted attribute values. Where is
it wrong?

Inside a `<script>` block and inside a URL. `<a href="{{link}}">` with a value
of `javascript:alert(1)` is escaped correctly and still runs. In a URL the
problem is the *scheme*, not the characters. And a value
substituted into JavaScript needs JavaScript escaping, where `</script>`
inside a string literal ends the block regardless of how the quotes are
handled. It is also wrong in an unquoted attribute: `<a href={{link}}>` ends
the value at the first space, so a value like `x onmouseover=alert(1)` becomes
new markup without involving one of the five escaped characters.

So production engines are **context-aware**. They parse enough of the HTML to
know whether a hole sits in text, an attribute, a URL or a script. Then they
apply a different escaper to each. Go's `html/template` does this and is the
standard reference for it. A single escaper is much better than none, but it
is not enough on its own.

## If you have written C

Substitution in C is a loop with a search and a lot of pointer arithmetic to
decide how much to copy between holes. It is one of the easier things to write
in C, because everything is a length and an offset.

The escaping is harder, because of sizing. The escaped string is longer than
the input. It is up to six times longer if the input is all double quotes,
since `&quot;` is six characters. So the output buffer cannot be the input's
length. You either compute the size in a first pass, grow the buffer as you
go, or write straight to the socket. The version above writes to the writer
directly, so it never needs to know the size. That is usually the right
choice, because the escaped text never needs to exist as a whole.

## Where this section stands

The seven chapters so far parse a request, answer over a socket, serve files
without exposing the whole disk, route, read forms, remember users, and render
pages without running what users typed. Together they make a small web server.

The parts that are missing are mostly about scale, not new ideas: keep-alive, chunked bodies, compression, TLS, and
concurrency, which [many clients](https://www.ziglang.in/learn/networking/many-clients/) covers.
File uploads have their own chapter, [File
Uploads](https://www.ziglang.in/learn/web-server/multipart/), because `multipart/form-data` is a
second body format and not a variation on the first.
