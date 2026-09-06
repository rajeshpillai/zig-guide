# A Stylesheet and the Cascade

> Matching is easy. Deciding which match wins is what cascading means.

A stylesheet is a list of rules, and a rule is a selector plus some
declarations. Parsing it is the least interesting parser in this guide: split
on `{`, split on `;`, split on `:`.

The interesting part is that **several rules match the same element and say
different things**, and something has to decide. That decision is what the C
in CSS stands for, and it is the only genuinely subtle thing about the
language.

## The rule

Two comparisons, in order.

1. **Specificity.** How precisely does the selector describe the element?
2. **Source order.** If specificity ties, the later rule wins.

That is the whole cascade, and everything people say about CSS being
unpredictable comes from misremembering the first one.

## The program

```zig
const std = @import("std");
const dom = @import("html.zig");

/// Three counts, compared left to right. Not one number: the familiar
/// 100/10/1 weighting is a simplification that breaks, and the check-yourself
/// on the chapter shows where.
pub const Specificity = struct {
    ids: u16 = 0,
    classes: u16 = 0,
    tags: u16 = 0,

    pub fn beats(a: Specificity, b: Specificity) bool {
        if (a.ids != b.ids) return a.ids > b.ids;
        if (a.classes != b.classes) return a.classes > b.classes;
        return a.tags > b.tags;
    }
};

pub const Selector = struct {
    tag: ?[]const u8 = null,
    class: ?[]const u8 = null,
    id: ?[]const u8 = null,

    pub fn specificity(s: Selector) Specificity {
        return .{
            .ids = if (s.id != null) 1 else 0,
            .classes = if (s.class != null) 1 else 0,
            .tags = if (s.tag != null) 1 else 0,
        };
    }

    /// Every component present must match. An absent component matches
    /// anything, which is why `*` needs no special case.
    pub fn matches(s: Selector, node: dom.Node) bool {
        if (node.kind != .element) return false;
        if (s.tag) |t| {
            if (!std.ascii.eqlIgnoreCase(node.name, t)) return false;
        }
        if (s.id) |want| {
            const got = node.attr("id") orelse return false;
            if (!std.mem.eql(u8, got, want)) return false;
        }
        if (s.class) |want| {
            const got = node.attr("class") orelse return false;
            var classes = std.mem.tokenizeAny(u8, got, " ");
            var found = false;
            while (classes.next()) |c| {
                if (std.mem.eql(u8, c, want)) found = true;
            }
            if (!found) return false;
        }
        return true;
    }
};

pub const Declaration = struct { property: []const u8, value: []const u8 };

pub const Rule = struct {
    selector: Selector,
    decls: [8]Declaration = undefined,
    decl_count: u8 = 0,
    /// Position in the stylesheet. Ties in specificity are broken by this,
    /// which is the entire reason "put your overrides last" works.
    order: u16 = 0,
};

fn parseSelector(text: []const u8) Selector {
    var s: Selector = .{};
    var rest = std.mem.trim(u8, text, " \t\n");
    if (rest.len == 0) return s;

    // Tag name, if the selector does not start with a marker.
    if (rest[0] != '.' and rest[0] != '#' and rest[0] != '*') {
        const end = std.mem.findAny(u8, rest, ".#") orelse rest.len;
        s.tag = rest[0..end];
        rest = rest[end..];
    } else if (rest[0] == '*') {
        rest = rest[1..];
    }

    while (rest.len > 0) {
        const marker = rest[0];
        rest = rest[1..];
        const end = std.mem.findAny(u8, rest, ".#") orelse rest.len;
        const name = rest[0..end];
        if (marker == '.') s.class = name else s.id = name;
        rest = rest[end..];
    }
    return s;
}

pub fn parse(source: []const u8, out: []Rule) ![]Rule {
    var n: usize = 0;
    var rest = source;

    while (std.mem.findScalar(u8, rest, '{')) |open| {
        const close = std.mem.findScalar(u8, rest, '}') orelse break;
        if (n == out.len) return error.TooManyRules;

        var rule: Rule = .{ .selector = parseSelector(rest[0..open]), .order = @intCast(n) };

        var decls = std.mem.splitScalar(u8, rest[open + 1 .. close], ';');
        while (decls.next()) |decl| {
            const colon = std.mem.findScalar(u8, decl, ':') orelse continue;
            if (rule.decl_count == rule.decls.len) break;
            rule.decls[rule.decl_count] = .{
                .property = std.mem.trim(u8, decl[0..colon], " \t\n"),
                .value = std.mem.trim(u8, decl[colon + 1 ..], " \t\n"),
            };
            rule.decl_count += 1;
        }

        out[n] = rule;
        n += 1;
        rest = rest[close + 1 ..];
    }
    return out[0..n];
}

/// The cascade: every declaration that matches, with the winner decided by
/// specificity first and source order second. There is no third tiebreak,
/// because two identical selectors in the same sheet are ordered by position.
pub fn cascade(rules: []const Rule, node: dom.Node, property: []const u8) ?[]const u8 {
    var best: ?Declaration = null;
    var best_spec: Specificity = .{};
    var best_order: u16 = 0;

    for (rules) |rule| {
        if (!rule.selector.matches(node)) continue;
        for (rule.decls[0..rule.decl_count]) |decl| {
            if (!std.mem.eql(u8, decl.property, property)) continue;
            const spec = rule.selector.specificity();
            const wins = best == null or spec.beats(best_spec) or
                (!best_spec.beats(spec) and rule.order >= best_order);
            if (wins) {
                best = decl;
                best_spec = spec;
                best_order = rule.order;
            }
        }
    }
    return if (best) |d| d.value else null;
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const stylesheet =
        \\p { color: black; margin: 0 }
        \\.warning { color: orange }
        \\p.warning { color: red; margin: 8 }
        \\#urgent { color: crimson }
        \\p { margin: 4 }
    ;

    var rules_buf: [16]Rule = undefined;
    const rules = try parse(stylesheet, &rules_buf);

    try out.print("{d} rules\n", .{rules.len});
    var text: [32]u8 = undefined;
    for (rules) |rule| {
        const s = rule.selector.specificity();
        var w: std.Io.Writer = .fixed(&text);
        if (rule.selector.tag) |t| try w.print("{s}", .{t});
        if (rule.selector.class) |c| try w.print(".{s}", .{c});
        if (rule.selector.id) |i| try w.print("#{s}", .{i});
        try out.print("  order {d}  specificity {d},{d},{d}  {s}\n", .{
            rule.order, s.ids, s.classes, s.tags, w.buffered(),
        });
    }

    const html = "<p class=\"warning\" id=\"urgent\">Careful</p><p>Ordinary</p>";
    var nodes: [16]dom.Node = undefined;
    const tree = try dom.parseInto(html, &nodes);

    try out.writeAll("\nwhat each element gets\n");
    var child = nodes[tree.root].first;
    while (child) |c| : (child = nodes[c].next) {
        const node = nodes[c];
        if (node.kind != .element) continue;
        try out.print("  <{s} class={s} id={s}>\n", .{
            node.name,
            node.attr("class") orelse "-",
            node.attr("id") orelse "-",
        });
        for ([_][]const u8{ "color", "margin" }) |property| {
            try out.print("    {s: <7} {s}\n", .{ property, cascade(rules, node, property) orelse "(unset)" });
        }
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`21-browser.css`)*

## What just happened

**`<p class="warning" id="urgent">` got `color: crimson`.** Four rules matched
it, saying black, orange, red and crimson. `#urgent` won because an id beats
any number of classes, and that is specificity doing its job.

**The same element got `margin: 8`, from `p.warning`.** Only two rules mention
margin: `p` at specificity 0,0,1 and `p.warning` at 0,1,1. The class component
decides it.

**The plain `<p>` got `margin: 4`, from the last rule.** Two rules with the
identical selector `p` both set margin. Specificity ties, so source order
breaks it, and the later one wins. This is the mechanism behind every "just
put your overrides at the bottom" instruction anybody has ever given you.

**Specificity is three numbers, not one.** The output shows them separately:
`0,1,1` for `p.warning`, `1,0,0` for `#urgent`. They are compared left to
right, like version numbers, so any id beats any number of classes.

## Check yourself

You will often see specificity described as a single score: 100 for an id, 10
for a class, 1 for a tag, add them up. Where does that break?

At eleven classes. It scores 110 under that scheme, which beats an id's 100.
In a real browser it does not. The comparison is component by component, so an
id beats any number of classes no matter how large the middle number gets.

The weighting is a teaching shortcut that happens to give the right answer for
every realistic stylesheet, which is why it survives. It is worth knowing it
is a shortcut, because the moment you build something that *computes*
specificity, using one number is a bug rather than a simplification. The
implementation above uses a struct with three fields for that reason.

## What this one leaves out

**Inheritance.** Some properties, `color` among them, are inherited by children
that do not set them, and others, `margin` among them, are not. That list is
per-property and defined by the spec, and the next chapter needs it, because a
paragraph inside a styled div takes its colour from somewhere.

**Combinators.** `div p` matches a `p` with a `div` ancestor, and `div > p`
requires it to be the parent. Both need the tree rather than the node, which
makes matching a walk upwards rather than a test in isolation. That is why
selector matching in real engines runs right-to-left: start from the element
you have and walk up, rather than finding every candidate and searching down.

`!important` sits above specificity entirely. The reason it exists at all is
user stylesheets: a reader who needs larger text has to be able to overrule
the page.

## If you have written C

The parsing is `strtok` on braces and semicolons and holds no surprises. The
part worth thinking about is the matching, because it is the hot loop of a
browser.

Naively, styling a document is every rule against every element, which is
rules times nodes and is far too slow for a real stylesheet against a real
page. Engines instead index the rules by their rightmost component, into hash
maps keyed on tag, class and id. An element then only ever tests the handful
of rules that could possibly match it. That is why the shape of your selectors
affects performance at all, and why a selector ending in `*` is the one that
costs.

The other C-specific concern is that every string here points into the
stylesheet source, so the source must outlive the parsed rules. That is the
same borrowing decision as everywhere else in this track. In a browser it is
why a stylesheet's bytes are kept alive for as long as the page is.

Next: layout, which turns this tree of styled nodes into rectangles with
positions.
