# A Lexer

> Characters in, tokens out, with one character of lookahead and no backtracking.

A compiler is not one program that understands your source. It is a short
pipeline of programs, each of which takes the output of the last and knows
almost nothing about the others. This section builds that pipeline, and the
first stage is the one that turns characters into words.

Source code arrives as bytes. `let total = 0;` is fourteen of them, and
nothing in there says that `let` is a keyword or that `total` is one name
rather than five letters. Deciding that is *lexing*, and doing it as a
separate pass is what makes everything downstream tractable. The parser never
sees a space, never counts a digit, and never wonders whether an identifier
starts with a keyword.

## The program

```zig
const std = @import("std");

pub const Kind = enum {
    number,
    identifier,
    plus,
    minus,
    star,
    slash,
    lparen,
    rparen,
    lbrace,
    rbrace,
    semi,
    comma,
    assign,
    eq,
    lt,
    kw_let,
    kw_print,
    kw_if,
    kw_else,
    kw_while,
    kw_fn,
    kw_return,
    eof,
    invalid,
};

pub const Token = struct {
    kind: Kind,
    /// Points into the source. The token owns nothing.
    text: []const u8,
    value: i64 = 0,
    line: usize = 1,
};

/// The words that are not identifiers. Checked after scanning a word, which is
/// why `letter` lexes as an identifier and not as `let` followed by `ter`:
/// the scan is greedy first, and the lookup happens on the whole word.
fn keyword(word: []const u8) ?Kind {
    const table = .{
        .{ "let", Kind.kw_let },
        .{ "print", Kind.kw_print },
        .{ "if", Kind.kw_if },
        .{ "else", Kind.kw_else },
        .{ "while", Kind.kw_while },
        .{ "fn", Kind.kw_fn },
        .{ "return", Kind.kw_return },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, word, entry[0])) return entry[1];
    }
    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

/// Fill `out` with the tokens of `source`, returning the part used.
pub fn tokenize(source: []const u8, out: []Token) ![]Token {
    var i: usize = 0;
    var line: usize = 1;
    var n: usize = 0;

    while (i < source.len) {
        const c = source[i];

        // Whitespace carries no meaning beyond separating tokens, so it is
        // dropped here and the parser never has to think about it again.
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }

        if (n == out.len) return error.TooManyTokens;
        const start = i;

        if (isDigit(c)) {
            var value: i64 = 0;
            while (i < source.len and isDigit(source[i])) : (i += 1) {
                value = value * 10 + (source[i] - '0');
            }
            out[n] = .{ .kind = .number, .text = source[start..i], .value = value, .line = line };
        } else if (isAlpha(c)) {
            while (i < source.len and (isAlpha(source[i]) or isDigit(source[i]))) : (i += 1) {}
            const word = source[start..i];
            out[n] = .{ .kind = keyword(word) orelse .identifier, .text = word, .line = line };
        } else {
            i += 1;
            // The only place lookahead is needed: `=` and `==` start the same.
            const kind: Kind = switch (c) {
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '(' => .lparen,
                ')' => .rparen,
                '{' => .lbrace,
                '}' => .rbrace,
                ';' => .semi,
                ',' => .comma,
                '<' => .lt,
                '=' => blk: {
                    if (i < source.len and source[i] == '=') {
                        i += 1;
                        break :blk .eq;
                    }
                    break :blk .assign;
                },
                else => .invalid,
            };
            out[n] = .{ .kind = kind, .text = source[start..i], .line = line };
        }
        n += 1;
    }

    if (n == out.len) return error.TooManyTokens;
    out[n] = .{ .kind = .eof, .text = "", .line = line };
    return out[0 .. n + 1];
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const source =
        \\let total = 0;
        \\while (total < 10) {
        \\  total = total + 3;
        \\}
        \\print total;
    ;

    var storage: [128]Token = undefined;
    const tokens = try tokenize(source, &storage);

    try out.print("{d} tokens\n\n", .{tokens.len});
    for (tokens) |token| {
        try out.print("line {d}  {t: <12} \"{s}\"", .{ token.line, token.kind, token.text });
        if (token.kind == .number) try out.print("  value {d}", .{token.value});
        try out.writeAll("\n");
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.lexer`)*

## What just happened

**Whitespace vanished, and that is the point.** The parser in the next chapter
will never handle a space, a tab, or a newline, because they are consumed here
and produce no token. Every stage after this one is simpler for it. The line
number survives, though, attached to each token, because an error message
without a line number is nearly useless and this is the only stage that still
knows.

**`total` came out as one token, not five.** The scan is greedy: once a letter
starts a word, it keeps taking letters and digits until it meets something
else. That single rule is why `total3` is one identifier and why `3total` is a
number followed by an identifier, which the parser will reject as it should.

**Keywords are identifiers that lost a lookup.** The scanner does not try to
match `let` up front. It scans the whole word and then checks the table, which
is the only order that works: matching `let` eagerly would lex `letter` as
`let` followed by `ter`. Every language with keywords does it this way.

**`=` and `==` are why lookahead exists.** After consuming `=`, the scanner
peeks at the next character before deciding which token it made. One character
is enough for this language, and one character is enough for most. When a
language needs more, that is a real design cost, and it is why `>>` in old C++
generic syntax was such a famous problem.

**Nothing was allocated.** Every token's `text` is a slice pointing back into
the source, so the tokens are meaningless once the source goes away, and
producing them copied nothing. That is the same borrowing decision as
[sort](https://www.ziglang.in/learn/unix-tools/sort/), and it is worth noticing that a compiler
makes it too.

## Check yourself

The lexer never rejects `let let = 3;` or `4 5 6`. Should it?

No, and the split is deliberate. A lexer's job is to say what the *words* are,
not whether the sentence makes sense. Both of those inputs are perfectly valid
token streams, and both are errors, and it is the parser that will say so. Two
stages with a clean boundary beat one stage that does both jobs and cannot
explain which one failed.

## If you have written C

The C version of this is a `switch` on the current character inside a loop,
with an enum of token types and a struct holding a pointer, a length and a
line number. That is exactly what is above. The differences are small and
worth naming.

C's token would hold `char *start; int len;` as two fields you keep in step by
hand. A Zig slice is those two fields with the language enforcing that they
travel together.

And C's keyword lookup is usually a chain of `strcmp` calls. The version here
uses a comptime `inline for` over a table, so the comparisons are generated
but the table is written once. Neither is a hash, and neither needs to be at
seven keywords.

Next: a parser, which takes this flat list and finds the structure in it.
