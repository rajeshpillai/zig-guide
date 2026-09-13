//! title: Labelled Switch
//! A switch with a label is a state machine: `continue :label value` runs it again.

const std = @import("std");

const Tag = enum { identifier, number, equal, semicolon, invalid, eof };

const Token = struct { tag: Tag, start: usize, end: usize };

const State = enum { start, identifier, number };

// One token from `src`, starting at `index.*`.
//
// The source is zero-terminated, like the one std.zig.Tokenizer reads, so the
// terminator is the end-of-input byte and no prong checks a length.
fn next(src: [:0]const u8, index: *usize, out: *std.Io.Writer) !Token {
    var i = index.*;
    var start = i;

    const tag: Tag = state: switch (State.start) {
        .start => {
            try visit(out, "start", src, i);
            switch (src[i]) {
                0 => break :state .eof,
                ' ' => {
                    i += 1;
                    start = i;
                    continue :state .start;
                },
                'a'...'z', '_' => {
                    i += 1;
                    continue :state .identifier;
                },
                '0'...'9' => {
                    i += 1;
                    continue :state .number;
                },
                '=' => {
                    i += 1;
                    break :state .equal;
                },
                ';' => {
                    i += 1;
                    break :state .semicolon;
                },
                else => {
                    i += 1;
                    break :state .invalid;
                },
            }
        },
        .identifier => {
            try visit(out, "identifier", src, i);
            switch (src[i]) {
                'a'...'z', '_', '0'...'9' => {
                    i += 1;
                    continue :state .identifier;
                },
                else => break :state .identifier,
            }
        },
        .number => {
            try visit(out, "number", src, i);
            switch (src[i]) {
                '0'...'9' => {
                    i += 1;
                    continue :state .number;
                },
                else => break :state .number,
            }
        },
    };

    index.* = i;
    return .{ .tag = tag, .start = start, .end = i };
}

fn visit(out: *std.Io.Writer, state: []const u8, src: [:0]const u8, i: usize) !void {
    if (src[i] == 0) {
        try out.print("  {s:<10}  src[{d}] is the terminator\n", .{ state, i });
    } else {
        try out.print("  {s:<10}  src[{d}] = '{c}'\n", .{ state, i, src[i] });
    }
}

// The same tokenizer written the way it had to be before Zig 0.14: a loop
// around a switch, with the state kept in a variable.
fn nextLoop(src: [:0]const u8, index: *usize) Token {
    var i = index.*;
    var start = i;
    var state: State = .start;

    const tag: Tag = while (true) {
        switch (state) {
            .start => switch (src[i]) {
                0 => break .eof,
                ' ' => {
                    i += 1;
                    start = i;
                },
                'a'...'z', '_' => {
                    i += 1;
                    state = .identifier;
                },
                '0'...'9' => {
                    i += 1;
                    state = .number;
                },
                '=' => {
                    i += 1;
                    break .equal;
                },
                ';' => {
                    i += 1;
                    break .semicolon;
                },
                else => {
                    i += 1;
                    break .invalid;
                },
            },
            .identifier => switch (src[i]) {
                'a'...'z', '_', '0'...'9' => i += 1,
                else => break .identifier,
            },
            .number => switch (src[i]) {
                '0'...'9' => i += 1,
                else => break .number,
            },
        }
    };

    index.* = i;
    return .{ .tag = tag, .start = start, .end = i };
}

const Instruction = union(enum) {
    push: i32,
    add,
    mul,
    halt,
};

// A tiny stack machine. The operand of every `continue` is the next
// instruction, which is only known at run time.
fn run(code: []const Instruction) i32 {
    var stack: [8]i32 = undefined;
    var sp: usize = 0;
    var ip: usize = 0;

    return vm: switch (code[ip]) {
        .push => |n| {
            stack[sp] = n;
            sp += 1;
            ip += 1;
            continue :vm code[ip];
        },
        .add => {
            sp -= 1;
            stack[sp - 1] += stack[sp];
            ip += 1;
            continue :vm code[ip];
        },
        .mul => {
            sp -= 1;
            stack[sp - 1] *= stack[sp];
            ip += 1;
            continue :vm code[ip];
        },
        .halt => stack[sp - 1],
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const src: [:0]const u8 = "n2 = 40;";
    try out.print("source: \"{s}\"\n", .{src});

    var index: usize = 0;
    var loop_index: usize = 0;
    var agree = true;
    while (true) {
        const token = try next(src, &index, out);
        const again = nextLoop(src, &loop_index);
        if (!std.meta.eql(token, again)) agree = false;

        try out.print("{s} \"{s}\"\n", .{ @tagName(token.tag), src[token.start..token.end] });
        if (token.tag == .eof) break;
    }
    try out.print("loop form agrees: {}\n\n", .{agree});

    // (2 + 3) * 4
    const program = [_]Instruction{ .{ .push = 2 }, .{ .push = 3 }, .add, .{ .push = 4 }, .mul, .halt };
    try out.print("(2 + 3) * 4 = {d}\n", .{run(&program)});

    try out.flush();
}
