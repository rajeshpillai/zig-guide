//! title: phrase
//! A passphrase generator whose word list is inside the program. The compiler
//! reads words.txt, checks every line, and turns it into a table, so the
//! program needs no file at run time and starts with the work already done.

const std = @import("std");

const Io = std.Io;

/// The bytes of words.txt, read by the compiler and stored in the program.
const words_txt = @embedFile("words.txt");

/// The table, built while compiling. A bad line in words.txt is a compile
/// error, so a program with a broken word list cannot be built at all.
const words = parseWords(words_txt);

/// 256 words, so one random byte picks one word, and each word adds 8 bits.
const word_count = 256;

fn parseWords(comptime text: []const u8) [word_count][]const u8 {
    // The duplicate check below compares every pair of words, about 32,000
    // comparisons. The compiler stops a long computation unless it is told to
    // expect one.
    @setEvalBranchQuota(2_000_000);

    var list: [word_count][]const u8 = undefined;
    var n: usize = 0;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0) continue;

        for (line) |c| {
            if (c < 'a' or c > 'z') @compileError(std.fmt.comptimePrint(
                "words.txt line {d}: \"{s}\" must be one word in lowercase a to z",
                .{ line_number, line },
            ));
        }
        for (list[0..n]) |seen| {
            if (std.mem.eql(u8, seen, line)) @compileError(std.fmt.comptimePrint(
                "words.txt line {d}: \"{s}\" is already in the list",
                .{ line_number, line },
            ));
        }
        if (n == word_count) @compileError(std.fmt.comptimePrint(
            "words.txt has more than {d} words",
            .{word_count},
        ));

        list[n] = line;
        n += 1;
    }
    if (n != word_count) @compileError(std.fmt.comptimePrint(
        "words.txt has {d} words, and it needs exactly {d}",
        .{ n, word_count },
    ));
    return list;
}

/// One word per byte, joined with dashes.
fn writePhrase(out: *Io.Writer, bytes: []const u8) !void {
    for (bytes, 0..) |b, i| {
        if (i > 0) try out.writeByte('-');
        try out.writeAll(words[b]);
    }
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("{d} words, {d} bytes of words.txt, inside the program\n", .{ words.len, words_txt.len });
    try out.print("first word: {s}, last word: {s}\n\n", .{ words[0], words[words.len - 1] });

    // Six words of 8 bits each is a 48-bit passphrase.
    var bytes: [6]u8 = undefined;
    try out.print("{d} words, {d} bits:\n", .{ bytes.len, bytes.len * 8 });

    // A fixed seed, so these three are the same on every run and the page can
    // check them. Never use a seeded generator for a real passphrase: anyone
    // with the seed gets the same words.
    var prng: std.Random.Xoshiro256 = .init(2026);
    for (0..3) |_| {
        prng.random().bytes(&bytes);
        try writePhrase(out, &bytes);
    }
    try out.flush();

    // The real one. `io.random` comes from the operating system's secure
    // random source, so this line is different every time. It goes to stderr,
    // because the check that runs this program compares stdout, and this line
    // can never match.
    io.random(&bytes);
    var err_buf: [256]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &err_buf);
    try stderr.interface.writeAll("\nyours, from the system's random source:\n");
    try writePhrase(&stderr.interface, &bytes);
    try stderr.interface.flush();
}
