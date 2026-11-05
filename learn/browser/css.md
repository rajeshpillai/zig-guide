# A Stylesheet and the Cascade

> To match a rule is easy. The cascade is the decision about which match wins.

A stylesheet is a list of rules. A rule is a selector and some declarations. The parser is simple: split on `{`, then split on `;`, then split on `:`.

The difficult part is this: **several rules match the same element, and the rules give different values**. Something must decide which rule wins. That decision is the cascade, the C in CSS.

## The rule

The cascade makes two comparisons, in this order:

1. **Specificity.** How precisely does the selector describe the element?
2. **Source order.** If the specificity is equal, the later rule wins.

The cascade has no other comparisons. When CSS seems unpredictable, the cause is usually a wrong idea about specificity.

## The program

```zig
const std = @import("std");
const dom = @import("html.zig");

/// Three counts. Compare them from left to right, and never add them into
/// one number. The common 100/10/1 weights are a simplification that gives
/// wrong answers. The "Check yourself" in the chapter shows where.
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

    /// Each component that is present must match. A component that is absent
    /// matches all values. Thus `*` needs no special case.
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
    /// The position in the stylesheet. When two specificities are equal, the
    /// position decides. Thus the advice "put your overrides last" works.
    order: u16 = 0,
};

fn parseSelector(text: []const u8) Selector {
    var s: Selector = .{};
    var rest = std.mem.trim(u8, text, " \t\n");
    if (rest.len == 0) return s;

    // The tag name, if the selector does not start with a marker.
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

/// The cascade: find each declaration that matches. Specificity decides the
/// winner first, and source order decides second. A third tiebreak is not
/// necessary, because each rule in the sheet has a different position.
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

**`<p class="warning" id="urgent">` got `color: crimson`.** Each rule in the sheet matched the element, and four of the rules set a colour: black, orange, red and crimson. `#urgent` won, because an id beats any number of classes. That is specificity.

**The same element got `margin: 8`, from `p.warning`.** Three rules set a margin. Two of them are the plain `p`, with a specificity of 0,0,1. `p.warning` has 0,1,1, and it beats both. The class component makes the decision.

**The plain `<p>` got `margin: 4`, from the last rule.** Two rules with the same selector `p` set a margin. The specificity is equal, thus the source order makes the decision, and the later rule wins. This is the reason for the advice "put your overrides at the bottom".

**Specificity is three numbers, not one.** The output shows the three numbers separately: `0,1,1` for `p.warning` and `1,0,0` for `#urgent`. The cascade compares them from left to right, as you compare version numbers. Thus any id beats any number of classes.

## Check yourself

Many texts describe specificity as one score: 100 for an id, 10 for a class and 1 for a tag, added together. Where does this score give the wrong answer?

It gives the wrong answer at eleven classes. Eleven classes get a score of 110, and 110 beats the 100 of an id. In a real browser, the id wins. The comparison is one component at a time. Thus an id beats any number of classes, however large the middle number is.

The single score is a shortcut that teachers use. It gives the correct answer for each realistic stylesheet, and thus people continue to use it. But when you build a program that *computes* specificity, one number is a bug. For this reason, the implementation above uses a struct with three fields.

## What this one leaves out

**Inheritance.** For some properties, for example `color`, a child that does not set the property inherits the value from its parent. For other properties, for example `margin`, the child does not inherit. The specification gives this rule for each property. The next chapter needs inheritance, because a paragraph in a styled div must get its colour from some place.

**Combinators.** `div p` matches a `p` that has a `div` ancestor. `div > p` matches only when the `div` is the parent. Both need the tree, not only the node. Thus the match becomes a walk up through the ancestors.

For this reason, real engines match selectors from right to left. They start from the element and walk up. They do not find all the candidates and then search down.

`!important` is above specificity. It exists because of user stylesheets. A reader who needs larger text must be able to overrule the page.

## If you know C

The parser is `strtok` on braces and semicolons, with no surprises. The match needs more thought, because it is the hot loop of a browser.

The simple method tests each rule against each element. The cost is the number of rules times the number of nodes. For a real stylesheet on a real page, that cost is much too slow.

Instead, engines put the rules in an index by the rightmost component. The index is a set of hash maps, with the tag, the class and the id as keys. Then an element tests only the few rules that can match it. This index is the reason that the shape of your selectors has an effect on performance. It is also the reason that a selector that ends in `*` is the slow one.

The other concern for a C programmer is that each string here points into the stylesheet source. Thus the source must live longer than the parsed rules. The remainder of this track makes the same decision to borrow. In a browser, this is the reason that the bytes of a stylesheet stay alive for as long as the page.

Next: layout, which changes this tree of styled nodes into rectangles with positions.
