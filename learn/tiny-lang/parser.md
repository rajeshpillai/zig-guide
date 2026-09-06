# A Parser

> One function per precedence level, each calling the tighter one.

The lexer produced a flat list. `1 + 2 * 3` is five tokens in a row, and a row
has no shape: nothing in it says which operation happens first. The parser's
job is to find the shape, and the shape is a tree.

The tree for `1 + 2 * 3` has `+` at the top, because it is the *last* thing
done. Its right operand is the whole of `2 * 3`. Reading a tree is reading
inwards-out, so the deepest node runs first, which means **precedence is
depth**.

That reframes the problem usefully. You do not need a rule that says `*` binds
tighter than `+`. You need `*` to end up deeper. And there is a way to write a
parser where that happens without anything ever consulting a table.

## The trick

Write one function per precedence level, loosest first, and have each one ask
the next-tighter level for its operands.

```
comparison  ->  sum   ( "<" | "==" sum )*
sum         ->  product   ( "+" | "-" product )*
product     ->  unary   ( "*" | "/" unary )*
unary       ->  "-" unary | primary
primary     ->  number | name | "(" comparison ")"
```

`sum` cannot see a `*`. By the time it looks at the token stream, `product`
has already consumed any multiplication and handed back a finished subtree. So
the multiplication is inside the addition's operand, which is exactly what
"binds tighter" means. The call chain *is* the precedence table.

This is **recursive descent**, and it is what most real compilers use, because
it is the only parsing technique you can read.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.parser`)*

## What just happened

**`1 + 2 * 3` became `(+ 1 (* 2 3))`** and `(1 + 2) * 3` became
`(* (+ 1 2) 3)`. Same five tokens in the first case as a naive left-to-right
reading would give, and a completely different tree.

**Parentheses needed no precedence rule.** `primary` sees a `(` and re-enters
at the *loosest* level, then expects a `)`. That is the whole implementation,
and it is why grouping works for any expression: it restarts the chain.

**`1 - 2 - 3` became `(- (- 1 2) 3)`, not `(- 1 (- 2 3))`.** Subtraction is
left-associative, and the loop is what makes it so: each level consumes
operators in a `while`, folding the result so far into the left side. Had it
recursed on the right instead, the same grammar would produce the other tree
and the answer would be -4 rather than 2. Right-associative operators, like
exponentiation in languages that have it, are written exactly that way on
purpose.

**The whole tree is one flat array.** A node holds indices, not pointers, and
children hang off a `first`/`next` linked list. So the parser allocates
nothing beyond the array it was handed, a node is a fixed size, and the tree
can be copied or thrown away in one move. Real compilers do this too, for the
cache behaviour as much as the simplicity.

**The error set is written out rather than inferred.** These functions are
mutually recursive, since `primary` calls back into `expression` for a
parenthesised group, and Zig cannot infer an error set around a cycle. The
first version of this snippet failed to compile with `dependency loop with
length 6`, which names the cycle rather than pointing at one function.

## Check yourself

The grammar says `while (cond) { ... }` with the parentheses required. Given
recursive descent, could the language drop them and accept `while cond { ...
}`?

Yes, and many languages do. The parentheses are not doing any parsing work
here. The condition ends where the block begins, and the expression parser
stops there on its own, because a brace is not an operator it recognises. What
the parentheses give you is a better error message when the condition is
malformed. They also keep the grammar unambiguous if you later add a construct
where an expression could be followed by a brace that means something else.
Rust requires the braces and forbids the parentheses for exactly this reason.

## If you have written C

The shape is identical, and this is one of the places where a C implementation
and a Zig one differ least. The nodes would be a `struct Node` with a `kind`
enum, a union of payloads, and `struct Node *` children.

Two differences worth naming. Using indices rather than pointers is a choice
in both languages. In C it is the one you make when you want to grow the node
array without invalidating everything pointing into it. Here it is also what
lets the whole tree live in a fixed array with no allocator at all.

And C's union payload would be untagged in practice, with the `kind` field
telling you which member is live and nothing checking that you agreed. That is
the classic source of a compiler bug that only shows up on one node type. Zig
has tagged unions for exactly this. The version above sidesteps the question
by giving every node the same fields, which is fine at ten node kinds and
would not be at fifty.

Next: an interpreter, which walks this tree and produces an answer.
