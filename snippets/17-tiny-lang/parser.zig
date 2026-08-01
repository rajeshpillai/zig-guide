//! title: A Parser
//! Recursive descent: one function per precedence level, each calling the tighter one.

const std = @import("std");
const lex = @import("lexer.zig");

pub const Kind = enum {
    number,
    variable,
    binary,
    unary,
    let,
    assign,
    print,
    @"if",
    @"while",
    block,
    fn_decl,
    call,
    ret,
};

/// Children are a linked list rather than a slice, so the whole tree lives in
/// one flat array and a node is a fixed size. `first` starts the list, `next`
/// continues it.
pub const Node = struct {
    kind: Kind,
    op: lex.Kind = .eof,
    value: i64 = 0,
    name: []const u8 = "",
    /// Operand, condition, or the value being assigned.
    a: ?u32 = null,
    /// Second operand, or the body of an if/while.
    b: ?u32 = null,
    /// The else branch.
    c: ?u32 = null,
    first: ?u32 = null,
    next: ?u32 = null,
};

/// Written out rather than inferred. These functions are mutually recursive
/// (`primary` re-enters `expression` for a parenthesised group), and inferred
/// error sets cannot close a cycle: the compiler reports a dependency loop.
pub const Error = error{ UnexpectedToken, TooManyNodes, TooManyTokens };

pub const Parser = struct {
    tokens: []const lex.Token,
    pos: usize = 0,
    nodes: []Node,
    used: u32 = 0,

    fn peek(p: *Parser) lex.Kind {
        return p.tokens[p.pos].kind;
    }

    fn accept(p: *Parser, kind: lex.Kind) bool {
        if (p.peek() != kind) return false;
        p.pos += 1;
        return true;
    }

    fn expect(p: *Parser, kind: lex.Kind) Error!lex.Token {
        if (p.peek() != kind) return error.UnexpectedToken;
        defer p.pos += 1;
        return p.tokens[p.pos];
    }

    fn add(p: *Parser, node: Node) Error!u32 {
        if (p.used == p.nodes.len) return error.TooManyNodes;
        p.nodes[p.used] = node;
        p.used += 1;
        return p.used - 1;
    }

    // Each level consumes its own operators and defers to the next one for the
    // operands. That call order *is* the precedence: `product` binds tighter
    // than `sum` because `sum` asks it for both sides before looking at `+`.

    pub fn expression(p: *Parser) Error!u32 {
        return p.comparison();
    }

    fn comparison(p: *Parser) Error!u32 {
        var left = try p.sum();
        while (p.peek() == .lt or p.peek() == .eq) {
            const op = p.peek();
            p.pos += 1;
            const right = try p.sum();
            left = try p.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
        }
        return left;
    }

    fn sum(p: *Parser) Error!u32 {
        var left = try p.product();
        while (p.peek() == .plus or p.peek() == .minus) {
            const op = p.peek();
            p.pos += 1;
            const right = try p.product();
            left = try p.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
        }
        return left;
    }

    fn product(p: *Parser) Error!u32 {
        var left = try p.unary();
        while (p.peek() == .star or p.peek() == .slash) {
            const op = p.peek();
            p.pos += 1;
            const right = try p.unary();
            left = try p.add(.{ .kind = .binary, .op = op, .a = left, .b = right });
        }
        return left;
    }

    fn unary(p: *Parser) Error!u32 {
        if (p.accept(.minus)) {
            return p.add(.{ .kind = .unary, .op = .minus, .a = try p.unary() });
        }
        return p.primary();
    }

    fn primary(p: *Parser) Error!u32 {
        const token = p.tokens[p.pos];
        switch (token.kind) {
            .number => {
                p.pos += 1;
                return p.add(.{ .kind = .number, .value = token.value });
            },
            .identifier => {
                p.pos += 1;
                // One token of lookahead decides between a name and a call.
                // This is the only place the expression grammar needs it.
                if (p.peek() != .lparen) {
                    return p.add(.{ .kind = .variable, .name = token.text });
                }
                p.pos += 1;
                const node = try p.add(.{ .kind = .call, .name = token.text });
                var last: ?u32 = null;
                while (p.peek() != .rparen) {
                    const arg = try p.expression();
                    if (last) |l| p.nodes[l].next = arg else p.nodes[node].first = arg;
                    last = arg;
                    if (!p.accept(.comma)) break;
                }
                _ = try p.expect(.rparen);
                return node;
            },
            // Parentheses need no precedence rule of their own. They re-enter
            // at the loosest level, which is what "override the grouping" means.
            .lparen => {
                p.pos += 1;
                const inner = try p.expression();
                _ = try p.expect(.rparen);
                return inner;
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn statement(p: *Parser) Error!u32 {
        if (p.accept(.kw_let)) {
            const name = try p.expect(.identifier);
            _ = try p.expect(.assign);
            const value = try p.expression();
            _ = try p.expect(.semi);
            return p.add(.{ .kind = .let, .name = name.text, .a = value });
        }
        if (p.accept(.kw_print)) {
            const value = try p.expression();
            _ = try p.expect(.semi);
            return p.add(.{ .kind = .print, .a = value });
        }
        if (p.accept(.kw_if)) {
            _ = try p.expect(.lparen);
            const cond = try p.expression();
            _ = try p.expect(.rparen);
            const then = try p.block();
            const other: ?u32 = if (p.accept(.kw_else)) try p.block() else null;
            return p.add(.{ .kind = .@"if", .a = cond, .b = then, .c = other });
        }
        if (p.accept(.kw_fn)) {
            const name = try p.expect(.identifier);
            _ = try p.expect(.lparen);
            const node = try p.add(.{ .kind = .fn_decl, .name = name.text });
            var last: ?u32 = null;
            while (p.peek() == .identifier) {
                const param = try p.expect(.identifier);
                const child = try p.add(.{ .kind = .variable, .name = param.text });
                if (last) |l| p.nodes[l].next = child else p.nodes[node].first = child;
                last = child;
                if (!p.accept(.comma)) break;
            }
            _ = try p.expect(.rparen);
            p.nodes[node].b = try p.block();
            return node;
        }
        if (p.accept(.kw_return)) {
            const value: ?u32 = if (p.peek() == .semi) null else try p.expression();
            _ = try p.expect(.semi);
            return p.add(.{ .kind = .ret, .a = value });
        }
        if (p.accept(.kw_while)) {
            _ = try p.expect(.lparen);
            const cond = try p.expression();
            _ = try p.expect(.rparen);
            const body = try p.block();
            return p.add(.{ .kind = .@"while", .a = cond, .b = body });
        }
        const name = try p.expect(.identifier);
        _ = try p.expect(.assign);
        const value = try p.expression();
        _ = try p.expect(.semi);
        return p.add(.{ .kind = .assign, .name = name.text, .a = value });
    }

    fn block(p: *Parser) Error!u32 {
        _ = try p.expect(.lbrace);
        const node = try p.add(.{ .kind = .block });
        try p.statementsUntil(node, .rbrace);
        _ = try p.expect(.rbrace);
        return node;
    }

    fn statementsUntil(p: *Parser, parent: u32, stop: lex.Kind) Error!void {
        var last: ?u32 = null;
        while (p.peek() != stop and p.peek() != .eof) {
            const child = try p.statement();
            if (last) |l| p.nodes[l].next = child else p.nodes[parent].first = child;
            last = child;
        }
    }

    pub fn program(p: *Parser) Error!u32 {
        const node = try p.add(.{ .kind = .block });
        try p.statementsUntil(node, .eof);
        return node;
    }
};

/// Print the tree as an S-expression, which is the shape with the syntax
/// removed: nesting is the only thing left, so precedence is visible.
pub fn show(nodes: []const Node, index: u32, out: *std.Io.Writer) !void {
    const node = nodes[index];
    switch (node.kind) {
        .number => try out.print("{d}", .{node.value}),
        .variable => try out.print("{s}", .{node.name}),
        .unary => {
            try out.writeAll("(neg ");
            try show(nodes, node.a.?, out);
            try out.writeAll(")");
        },
        .binary => {
            const symbol = switch (node.op) {
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .lt => "<",
                .eq => "==",
                else => "?",
            };
            try out.print("({s} ", .{symbol});
            try show(nodes, node.a.?, out);
            try out.writeAll(" ");
            try show(nodes, node.b.?, out);
            try out.writeAll(")");
        },
        .let, .assign => {
            try out.print("({s} {s} ", .{ if (node.kind == .let) "let" else "set", node.name });
            try show(nodes, node.a.?, out);
            try out.writeAll(")");
        },
        .print => {
            try out.writeAll("(print ");
            try show(nodes, node.a.?, out);
            try out.writeAll(")");
        },
        .@"if" => {
            try out.writeAll("(if ");
            try show(nodes, node.a.?, out);
            try out.writeAll(" ");
            try show(nodes, node.b.?, out);
            if (node.c) |else_branch| {
                try out.writeAll(" ");
                try show(nodes, else_branch, out);
            }
            try out.writeAll(")");
        },
        .@"while" => {
            try out.writeAll("(while ");
            try show(nodes, node.a.?, out);
            try out.writeAll(" ");
            try show(nodes, node.b.?, out);
            try out.writeAll(")");
        },
        .call => {
            try out.print("(call {s}", .{node.name});
            var arg = node.first;
            while (arg) |a| : (arg = nodes[a].next) {
                try out.writeAll(" ");
                try show(nodes, a, out);
            }
            try out.writeAll(")");
        },
        .ret => {
            try out.writeAll("(return");
            if (node.a) |value| {
                try out.writeAll(" ");
                try show(nodes, value, out);
            }
            try out.writeAll(")");
        },
        .fn_decl => {
            try out.print("(fn {s} (", .{node.name});
            var param = node.first;
            var first = true;
            while (param) |pa| : (param = nodes[pa].next) {
                if (!first) try out.writeAll(" ");
                try out.print("{s}", .{nodes[pa].name});
                first = false;
            }
            try out.writeAll(") ");
            try show(nodes, node.b.?, out);
            try out.writeAll(")");
        },
        .block => {
            try out.writeAll("(block");
            var child = node.first;
            while (child) |c| : (child = nodes[c].next) {
                try out.writeAll(" ");
                try show(nodes, c, out);
            }
            try out.writeAll(")");
        },
    }
}

pub fn parse(source: []const u8, tokens: []lex.Token, nodes: []Node) !struct { root: u32, used: u32 } {
    const stream = try lex.tokenize(source, tokens);
    var p: Parser = .{ .tokens = stream, .nodes = nodes };
    return .{ .root = try p.program(), .used = p.used };
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var tokens: [128]lex.Token = undefined;
    var nodes: [128]Node = undefined;

    // Precedence, with the syntax removed. Nothing consults a table: `*` ends
    // up deeper than `+` because `sum` called `product` first.
    try out.writeAll("precedence\n");
    for ([_][]const u8{ "1 + 2 * 3;", "(1 + 2) * 3;", "1 - 2 - 3;", "0 - -4;" }) |line| {
        const stream = try lex.tokenize(line, &tokens);
        var p: Parser = .{ .tokens = stream, .nodes = &nodes };
        const root = try p.expression();
        try out.print("  {s: <14} ", .{line});
        try show(&nodes, root, out);
        try out.writeAll("\n");
    }

    const source =
        \\let total = 0;
        \\while (total < 10) {
        \\  total = total + 3;
        \\}
        \\print total;
    ;

    const tree = try parse(source, &tokens, &nodes);
    try out.print("\nthe program, as a tree ({d} nodes)\n  ", .{tree.used});
    try show(&nodes, tree.root, out);
    try out.writeAll("\n");

    try out.flush();
}
