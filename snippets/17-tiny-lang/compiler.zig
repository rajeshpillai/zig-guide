//! title: A Bytecode Compiler
//! The same tree, walked once at compile time instead of once per execution.

const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("parser.zig");

pub const Op = enum {
    push,
    load,
    store,
    add,
    sub,
    mul,
    div,
    lt,
    eq,
    neg,
    print,
    jmp,
    jmp_if_false,
    halt,
};

/// One instruction. `arg` is a literal value, a slot number or a jump target.
/// The opcode decides which. A real VM packs the instruction into bytes. A
/// struct uses more memory, but you do not have to write a decoder. That
/// trade is good for code that people read.
pub const Instr = struct {
    op: Op,
    arg: i64 = 0,
};

pub const Error = error{
    TooManyInstructions,
    TooManySlots,
    UndefinedVariable,
    DivideByZero,
    WriteFailed,
};

pub const Chunk = struct {
    code: []Instr,
    len: u32 = 0,
    /// Names, in the order that the compiler first saw them. The index is the
    /// slot number. After the compile step, the compiler never needs the names.
    slots: [32][]const u8 = undefined,
    slot_count: u32 = 0,
};

pub const Compiler = struct {
    nodes: []const ast.Node,
    chunk: *Chunk,

    fn emit(c: *Compiler, op: Op, arg: i64) Error!u32 {
        if (c.chunk.len == c.chunk.code.len) return error.TooManyInstructions;
        c.chunk.code[c.chunk.len] = .{ .op = op, .arg = arg };
        c.chunk.len += 1;
        return c.chunk.len - 1;
    }

    /// Resolve a name to a number, one time, here. This is the fix that the
    /// interpreter chapter promised. At run time a variable is an array index,
    /// and the string comparison on each read does not occur.
    fn slot(c: *Compiler, name: []const u8) Error!i64 {
        for (c.chunk.slots[0..c.chunk.slot_count], 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return @intCast(i);
        }
        if (c.chunk.slot_count == c.chunk.slots.len) return error.TooManySlots;
        c.chunk.slots[c.chunk.slot_count] = name;
        c.chunk.slot_count += 1;
        return @intCast(c.chunk.slot_count - 1);
    }

    /// Post-order: emit the operands, then the operator. This order is all
    /// that you need to translate a tree for a stack machine. When `add` runs,
    /// its two inputs are already the top of the stack.
    pub fn compile(c: *Compiler, index: u32) Error!void {
        const node = c.nodes[index];
        switch (node.kind) {
            .number => _ = try c.emit(.push, node.value),
            .variable => _ = try c.emit(.load, try c.slot(node.name)),
            .unary => {
                try c.compile(node.a.?);
                _ = try c.emit(.neg, 0);
            },
            .binary => {
                try c.compile(node.a.?);
                try c.compile(node.b.?);
                _ = try c.emit(switch (node.op) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .slash => .div,
                    .lt => .lt,
                    else => .eq,
                }, 0);
            },
            .let, .assign => {
                try c.compile(node.a.?);
                _ = try c.emit(.store, try c.slot(node.name));
            },
            .print => {
                try c.compile(node.a.?);
                _ = try c.emit(.print, 0);
            },
            .@"if" => {
                try c.compile(node.a.?);
                // The target is not known yet, because the compiler did not
                // emit the then-branch yet. Emit a placeholder, remember its
                // position, and write the target later. That is backpatching.
                // Because of backpatching, a compiler can work in one pass.
                const skip_then = try c.emit(.jmp_if_false, 0);
                try c.compile(node.b.?);
                if (node.c) |other| {
                    const skip_else = try c.emit(.jmp, 0);
                    c.chunk.code[skip_then].arg = c.chunk.len;
                    try c.compile(other);
                    c.chunk.code[skip_else].arg = c.chunk.len;
                } else {
                    c.chunk.code[skip_then].arg = c.chunk.len;
                }
            },
            .@"while" => {
                // The backward jump needs no patch. The compiler emitted the
                // start of the loop before it emits the jump.
                const start = c.chunk.len;
                try c.compile(node.a.?);
                const exit = try c.emit(.jmp_if_false, 0);
                try c.compile(node.b.?);
                _ = try c.emit(.jmp, start);
                c.chunk.code[exit].arg = c.chunk.len;
            },
            .block => {
                var child = node.first;
                while (child) |ch| : (child = c.nodes[ch].next) try c.compile(ch);
            },
            else => {},
        }
    }
};

pub fn compileSource(source: []const u8, tokens: []lex.Token, nodes: []ast.Node, chunk: *Chunk) !void {
    const tree = try ast.parse(source, tokens, nodes);
    var c: Compiler = .{ .nodes = nodes, .chunk = chunk };
    try c.compile(tree.root);
    _ = try c.emit(.halt, 0);
}

pub fn disassemble(chunk: *const Chunk, out: *std.Io.Writer) !void {
    for (chunk.code[0..chunk.len], 0..) |instr, i| {
        try out.print("{d:0>3}  {t: <13}", .{ i, instr.op });
        switch (instr.op) {
            .push => try out.print(" {d}", .{instr.arg}),
            .load, .store => try out.print(" {d}    ; {s}", .{ instr.arg, chunk.slots[@intCast(instr.arg)] }),
            .jmp, .jmp_if_false => try out.print(" {d}", .{instr.arg}),
            else => {},
        }
        try out.writeAll("\n");
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var tokens: [256]lex.Token = undefined;
    var nodes: [256]ast.Node = undefined;
    var code: [128]Instr = undefined;

    try out.writeAll("an expression\n");
    {
        var chunk: Chunk = .{ .code = &code };
        try compileSource("print 1 + 2 * 3;", &tokens, &nodes, &chunk);
        try disassemble(&chunk, out);
    }

    try out.writeAll("\na loop\n");
    {
        var chunk: Chunk = .{ .code = &code };
        try compileSource(
            \\let total = 0;
            \\while (total < 10) {
            \\  total = total + 3;
            \\}
            \\print total;
        , &tokens, &nodes, &chunk);
        try disassemble(&chunk, out);
        try out.print("\n{d} slots: ", .{chunk.slot_count});
        for (chunk.slots[0..chunk.slot_count], 0..) |name, i| {
            try out.print("{d}={s} ", .{ i, name });
        }
        try out.writeAll("\n");
    }

    try out.flush();
}
