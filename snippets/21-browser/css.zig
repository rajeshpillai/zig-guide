//! title: A Stylesheet and the Cascade
//! Matching is easy. Deciding which match wins is what "cascading" means.

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
