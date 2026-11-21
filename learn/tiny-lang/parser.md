# A Parser

> One function for each precedence level. Each function calls the function for the next tighter level.

The lexer made a flat list. `1 + 2 * 3` is five tokens in a row, and a row has
no shape. Nothing in the row tells you which operation occurs first. The job of
the parser is to find the shape, and the shape is a tree.

In the tree for `1 + 2 * 3`, the `+` is at the top, because the `+` is the
*last* operation. The right operand of the `+` is all of `2 * 3`. A tree runs
from the deepest node to the top, thus the deepest node runs first. This means
that **precedence is depth**.

This fact gives a more useful view of the problem. You do not need a rule that
says `*` binds tighter than `+`. You need `*` to be deeper in the tree. It is
possible to write a parser that puts `*` deeper, and that parser never reads a
table.

## The method

Write one function for each precedence level, with the loosest level first.
Each function gets its operands from the function for the next tighter level.

```
comparison  ->  sum   ( "<" | "==" sum )*
sum         ->  product   ( "+" | "-" product )*
product     ->  unary   ( "*" | "/" unary )*
unary       ->  "-" unary | primary
primary     ->  number | name | "(" comparison ")"
```

`sum` cannot see a `*`. `sum` asks `product` for each operand. `product` reads
each multiplication and returns a complete subtree. Thus the multiplication is
inside the operand of the addition, and that is exactly the meaning of "binds
tighter". The call chain *is* the precedence table.

This method is called **recursive descent**. Most production compilers use it,
because the code is easy to read.

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

/// Children are a linked list, not a slice. Thus the full tree is in one flat
/// array, and each node has a fixed size. `first` starts the list, and `next`
/// continues it.
pub const Node = struct {
    kind: Kind,
    op: lex.Kind = .eof,
    value: i64 = 0,
    name: []const u8 = "",
    /// The operand, the condition, or the value for the assignment.
    a: ?u32 = null,
    /// The second operand, or the body of an if or a while.
    b: ?u32 = null,
    /// The else branch.
    c: ?u32 = null,
    first: ?u32 = null,
    next: ?u32 = null,
};

/// The error set is explicit, not inferred. These functions are mutually
/// recursive: `primary` calls `expression` again for a group in parentheses.
/// An inferred error set cannot close a cycle, and the compiler reports a
/// dependency loop.
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

    // Each level reads its own operators, and gets its operands from the next
    // level. That call order *is* the precedence. `product` binds tighter than
    // `sum`, because `sum` asks `product` for both sides before it examines `+`.

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
                // The expression grammar needs lookahead only here.
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
            // Parentheses need no precedence rule of their own. They start
            // again at the loosest level, and thus they change the order of
            // operations.
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

/// Print the tree as an S-expression. An S-expression is the shape without the
/// syntax. Only the nesting remains, thus the precedence is visible.
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

    // Precedence, without the syntax. Nothing reads a table. `*` is deeper
    // than `+` because `sum` called `product` first.
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

**`1 + 2 * 3` became `(+ 1 (* 2 3))`**, and `(1 + 2) * 3` became
`(* (+ 1 2) 3)`. A simple left-to-right order uses the same five tokens as the
first case, but it makes a completely different tree.

**Parentheses needed no precedence rule.** When `primary` sees a `(`, it starts
again at the *loosest* level, and then it expects a `)`. Nothing more is
necessary. Parentheses work for each expression, because they start the chain
again.

**`1 - 2 - 3` became `(- (- 1 2) 3)`, not `(- 1 (- 2 3))`.** Subtraction is
left-associative, and the loop makes it left-associative. Each level reads its
operators in a `while` loop, and puts the result so far into the left side. If
the function called itself for the right side instead, the same grammar would
make the other tree. Then the answer would be 2, not -4. A parser for a
right-associative operator, for example exponentiation in languages that have
it, intentionally uses that method.

**The full tree is one flat array.** A node holds indices, not pointers. The
children of a node are a linked list, through the `first` and `next` fields.
Thus the parser allocates nothing more than the array that it gets. Each node
has a fixed size, and the program can copy or discard the full tree in one
step. Production compilers also do this, for the cache behaviour as much as
for the simplicity.

**The code gives the error set explicitly, and Zig does not infer it.** These
functions are mutually recursive, because `primary` calls `expression` again
for a group in parentheses. Zig cannot infer an error set around a cycle. The
first version of this snippet did not compile. The error was `dependency loop
with length 6`, which names the cycle and does not point at one function.

## Check yourself

The grammar says `while (cond) { ... }`, and the grammar requires the
parentheses.
With recursive descent, can the language remove the parentheses and accept
`while cond { ... }`?

Yes, and many languages do this. Here, the parentheses do no parsing work. The
condition ends where the block starts. The expression parser stops at the
brace with no extra code, because a brace is not an operator that the parser
recognises.

The parentheses give you a better error message when the condition is
malformed. They also keep the grammar unambiguous if you add a construct
later, where a brace after an expression has a different meaning. Rust
requires the braces and warns about the parentheses for exactly this reason.

## If you know C

The shape is the same in C. The parser is one of the places where a C
implementation and a Zig implementation are the most similar. In C, the nodes
are a `struct Node` with a `kind` enum, a union of payloads, and `struct Node *`
children.

There are two differences. First, indices instead of pointers are a choice in
both languages. In C, you make that choice when you want to grow the node
array. Then the growth does not make each reference into the array invalid. Here, the choice also lets the full tree live in a fixed array, with
no allocator.

Second, in practice a C union payload has no tag. The `kind` field tells you
which member is live, and nothing checks that the field and the member agree.
This mismatch is the classic cause of a compiler bug that occurs on only one
node type. Zig gives you tagged unions for exactly this problem.

The version above avoids the question, because each node has the same fields.
That design is fine with thirteen node kinds, and it would not be fine with
fifty.

The next chapter is an interpreter. The interpreter walks this tree and
produces an answer.
