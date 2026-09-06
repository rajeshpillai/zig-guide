# A Bytecode Compiler

> The same tree, walked once at compile time instead of once per execution.

The interpreter walks the tree every time the program runs. Inside a loop, it
walks the same subtree on every iteration: chasing the same indices, switching
on the same node kinds, comparing the same variable names against the same
strings. None of that work depends on the values, so none of it needs to
happen more than once.

A compiler is what you get from taking that seriously. Walk the tree **once**,
and instead of computing an answer, write down the steps. The steps are
**bytecode**, and running the program becomes a loop over a flat array rather
than a walk over a tree.

Nothing about the answer changes. This is the same computation, with the
decisions moved earlier.

## The program

```zig
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

/// One instruction. `arg` is a literal value, a slot number, or a jump target,
/// depending on the opcode. A real VM packs this into bytes; keeping it a
/// struct costs memory and saves a decoder, which is the right trade for
/// something you are reading rather than shipping.
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
    /// Names, in the order they were first seen. The index is the slot number,
    /// and after compiling, the names are never needed again.
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

    /// Resolve a name to a number, once, here. This is the fix the interpreter
    /// chapter promised: at run time a variable is an array index, and the
    /// string comparison that used to happen on every read is gone.
    fn slot(c: *Compiler, name: []const u8) Error!i64 {
        for (c.chunk.slots[0..c.chunk.slot_count], 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return @intCast(i);
        }
        if (c.chunk.slot_count == c.chunk.slots.len) return error.TooManySlots;
        c.chunk.slots[c.chunk.slot_count] = name;
        c.chunk.slot_count += 1;
        return @intCast(c.chunk.slot_count - 1);
    }

    /// Post-order: emit the operands, then the operator. That ordering is the
    /// whole translation from a tree to a stack machine, because by the time
    /// `add` runs its two inputs are already the top of the stack.
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
                // The target is not known yet: the then-branch has not been
                // emitted. Emit a placeholder, remember where it is, and come
                // back. That is backpatching, and it is why a compiler can
                // work in a single pass over the tree.
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
                // The backward jump needs no patching: the loop's start is
                // already behind us when the jump is emitted.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.compiler`)*

## What just happened

**`1 + 2 * 3` became push, push, push, mul, add.** Operands first, then the
operator. That is post-order traversal, and it is the entire translation from
a tree to a stack machine. By the time an operator runs, its two inputs are
the top two things on the stack, because emitting the children put them there.
No instruction ever names its operands.

**Variables became numbers.** `load 0` with a comment saying `total`, and the
comment is only there for you. This is the fix the [interpreter
chapter](https://www.ziglang.in/learn/tiny-lang/interpreter/) promised when it admitted that a
linear search over names runs on every variable read. The search still
happens, once per mention, here at compile time. At run time a variable is an
array index.

That is most of what "compiled languages are faster" means, and it is not
magic: the same work, done at a time when it can be done once.

**The forward jump was patched.** When `jmp_if_false` is emitted, the address
to jump to is not known, because the body it needs to skip has not been
emitted yet. So a placeholder goes in, its position is remembered, and the
real target is written once the length is known. That is **backpatching**, and
it is what lets a compiler emit code in one pass over the tree instead of two.

Look at the loop: `jmp_if_false 11` was patched, and `jmp 2` was not. The
backward jump needed no patch, because a loop's start is already behind you
when you emit the jump to it. Forward jumps need patching; backward ones do
not.

**The slot table is not in the program.** It is printed at the end so you can
read the disassembly, but the bytecode holds only numbers. After compiling,
the names are debug information: useful in a stack trace, unnecessary to run.

## What this compiler does not do

It ignores `fn`, `return` and calls. The `else` prong in `compile` skips them
silently, so a program using functions compiles to bytecode that quietly
leaves them out.

That is a real limitation rather than an omission from the writing. Compiling
functions means designing a **calling convention**: where arguments go, how a
frame is addressed, how the return address is stored, whose job it is to clean
up. Every one of those is a decision with alternatives, which is why it gets
[its own chapter](https://www.ziglang.in/learn/tiny-lang/calls/) rather than a paragraph in this
one. Read this compiler first: it is the same one, without the part that makes
calls work.

## Check yourself

The compiler emits `store` for both `let x = 1;` and `x = 1;`, resolving both
to the same slot. What does that mean for a variable declared inside a `while`
body?

There is only one of it. Slots are allocated per *name*, for the whole
program. So a variable inside a loop reuses the same slot on every iteration,
and two variables with the same name in different functions would collide.
Real compilers give each scope its own range of slots and free them when the
scope ends. That is what makes locals cheap, and it is the same bookkeeping
the frames chapter did at run time. This one has a single flat namespace,
which is exactly enough for a language with no functions.

## If you have written C

C compiles to machine code rather than bytecode, but the middle of the
pipeline is the same shape. The disassembly above would be recognisable to
anyone who has read compiler output. A real back end differs in two ways worth
naming.

It has **registers**, so a value can stay in one across several operations
instead of being pushed and popped. Deciding which values live in which
registers is register allocation, and it is where a large part of a real
compiler's complexity lives. A stack machine skips the problem entirely, which
is why bytecode VMs are stack machines and why they are slower.

And it optimises, which is possible because the bytecode is now a data
structure you can rewrite. `push 1, push 2, add` can become `push 3` before
anything runs. This compiler does none of that, and the fact that it could is
the reason compiling and interpreting diverge in speed rather than only in
timing.

Next: the virtual machine, which runs what this just wrote.
