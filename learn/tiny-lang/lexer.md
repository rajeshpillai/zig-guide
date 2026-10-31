# A Lexer

> The lexer changes characters into tokens. It looks one character ahead and never moves back in the source.

A compiler is a short pipeline of programs. Each program takes the output of
the program before it, and knows almost nothing about the other programs. This
section builds that pipeline. The first stage changes characters into words.

Source code comes in as bytes. `let total = 0;` is fourteen bytes. Nothing in
the bytes says that `let` is a keyword, or that `total` is one name and not
five letters. The stage that makes these decisions is the *lexer*, and its work
is called *lexing*.

When lexing is a separate pass, each later stage is easier to write. The parser
never sees a space and never counts a digit. The parser also never checks if
an identifier starts with a keyword.

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
    /// A slice into the source. The token owns no memory.
    text: []const u8,
    value: i64 = 0,
    line: usize = 1,
};

/// The words that are not identifiers. The lexer checks this table after it
/// scans a full word. Thus `letter` lexes as an identifier, not as `let` and
/// then `ter`. The scan is greedy first, and the lookup uses the full word.
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

/// Put the tokens of `source` into `out`. Return the part of `out` that has tokens.
pub fn tokenize(source: []const u8, out: []Token) ![]Token {
    var i: usize = 0;
    var line: usize = 1;
    var n: usize = 0;

    while (i < source.len) {
        const c = source[i];

        // Whitespace has no meaning, except that it separates tokens. Thus the
        // lexer drops the whitespace here, and the parser never sees it.
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
            // Lookahead is necessary only here, because `=` and `==` start the same.
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

**The whitespace is gone.** The parser in the next chapter never sees a space,
a tab or a newline. The lexer reads these characters and makes no token for
them, thus each later stage is simpler. The line number stays, and each token
holds it. An error message without a line number is almost useless, and the
lexer is the last stage that knows the line.

**`total` became one token, not five.** The scan is greedy: it takes as many
characters as it can. When a letter starts a word, the scan continues to take
letters and digits until it finds a different character. Because of this one
rule, `total3` is one identifier. `3total` is a number and then an identifier,
and the parser correctly rejects it.

**A keyword is an identifier that the lexer finds in the keyword table.** The
scanner does not try to match `let` first. It scans the full word, and then it
searches the table for the word. Only this order works. If the scanner matched
`let` first, it would lex `letter` as `let` and then `ter`. Each language with
keywords uses this order.

**`=` and `==` are the reason for lookahead.** After the scanner reads `=`, it
examines the next character. Then it decides which token it made. One
character of lookahead is enough for this language, and for most languages.
When a language needs more lookahead, the design has a real cost. That cost is
the reason that `>>` in old C++ template syntax was a well-known problem.

**The lexer allocated nothing.** The `text` of each token is a slice that
points back into the source. The lexer copied no bytes to make the tokens.
When the program frees the source, the tokens become invalid. The
[sort](https://www.ziglang.in/learn/unix-tools/sort/) chapter made the same decision to borrow
memory, and a compiler makes the same decision too.

## Check yourself

The lexer never rejects `let let = 3;` or `4 5 6`. Should the lexer reject
them?

No, because the split is intentional. The job of a lexer is to identify the
*words*. The lexer does not check if the sentence has a meaning. Both inputs
are valid streams of tokens. Both inputs are also errors, and the parser
reports them. Because there are two separate stages, an error message can tell
you which stage failed.

## If you know C

In C, a lexer is a `switch` on the current character inside a loop. It has an
enum of token types, and a struct that holds a pointer, a length and a line
number. The code above does the same. There are some small differences.

A C token holds `char *start; int len;` as two fields, and you must keep the
two fields correct manually. A Zig slice is those two fields, and the language
keeps them together.

Also, a C keyword lookup is usually a chain of `strcmp` calls. The version here
uses a comptime `inline for` over a table. The compiler generates the
comparisons, but you write the table one time. Neither version uses a hash,
and with seven keywords neither version needs one.

The next chapter is a parser. The parser takes this flat list and finds the
structure in it.
