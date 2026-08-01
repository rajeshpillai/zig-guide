//! title: A Lexer
//! Characters in, tokens out. One character of lookahead and no backtracking.

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
