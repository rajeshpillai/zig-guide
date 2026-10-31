# A Bytecode Compiler

> The compiler walks the same tree one time at compile time, not one time for each run.

The interpreter walks the tree each time the program runs. Inside a loop, the
interpreter walks the same subtree on each iteration. It follows the same
indices, it switches on the same node kinds, and it compares the same variable
names with the same strings. None of that work depends on the values. Thus
that work never needs to occur more than one time.

A compiler removes that repeated work. The compiler walks the tree **one
time**. It does not calculate an answer. It writes down the steps, and the
steps are **bytecode**. Then, to run the program, a loop goes over a flat
array, not over a tree.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.compiler`)*

## What just happened

**`1 + 2 * 3` became push, push, push, mul, add.** The operands come first,
and then the operator. That order is a post-order traversal, and it is all
that you need to translate a tree for a stack machine. When an operator runs,
its two inputs are the top two values on the stack, because the code for the
children put them there. No instruction ever names its operands.

**Variables became numbers.** The listing shows `load 0` with a comment that
says `total`, and the comment is only for you. The
[interpreter chapter](https://www.ziglang.in/learn/tiny-lang/interpreter/) showed that the
interpreter does a linear search over names each time it reads a variable.
That chapter promised this fix. The search still occurs here, one time for
each mention, at compile time. At run time, a variable is an array index.

This change is a large part of the reason that compiled languages are faster.

**The compiler patched the forward jump.** When the compiler emits
`jmp_if_false`, it does not know the target address, because the body that the
jump skips does not exist yet. Thus the compiler writes a placeholder and
remembers its position. When the length of the body is known, the compiler
writes the real target. This method is called **backpatching**. It lets a
compiler emit code in one pass over the tree, not two.

Look at the loop. The compiler patched `jmp_if_false 11`, and it did not patch
`jmp 2`. The backward jump needed no patch, because the start of the loop is
already in the code when the compiler emits the jump to it. Forward jumps need
a patch, and backward jumps do not.

**The slot table is not in the program.** The program prints the table at the
end so that you can read the disassembly, but the bytecode holds only numbers.
After the compile step, the names are debug information. A stack trace can use
them, but the program does not need them to run.

## What this compiler does not do

The compiler ignores `fn`, `return` and calls. The `else` prong in `compile`
silently skips them. Thus a program that uses functions compiles to bytecode
without those functions, and no error tells you.

This is a real limit of the code. To compile functions, you must design a
**calling convention**. A calling convention decides these things:

- where the arguments go
- how the code addresses a frame
- how the code stores the return address
- which side removes the arguments after the call

Each of those is a decision with alternatives. Thus calls get
[their own chapter](https://www.ziglang.in/learn/tiny-lang/calls/). Read this compiler first. The
compiler in that chapter is the same, plus the part that makes calls work.

## Check yourself

The compiler emits `store` for both `let x = 1;` and `x = 1;`, and it resolves
both to the same slot. What does that mean for a variable that you declare
inside a `while` body?

There is only one copy of the variable. The compiler allocates slots by
*name*, for the full program. Thus a variable inside a loop uses the same slot
again on each iteration. Two variables with the same name in different
functions would collide.

Real compilers give each scope its own range of slots, and free the slots when
the scope ends. Slots for each scope make locals cheap. This is the same
bookkeeping that the frames chapter did at run time. This compiler has one
flat namespace, which is enough for a language without functions.

## If you know C

C compiles to machine code, not to bytecode, but the middle of the pipeline has
the same shape. A person who knows compiler output can recognise the
disassembly above. A real back end is different in two ways.

First, a real back end has **registers**. A value can stay in a register
across several operations, and the code does not push and pop the value.

The decision about which values go in which registers is called register
allocation. A large part of the complexity of a real compiler is in register
allocation. A stack machine does not have this problem at all. That is the
reason that many bytecode VMs are stack machines, and the reason that they are
slower. Lua and Dalvik made the other choice, and allocate registers.

Second, a real back end optimises. Optimisation is possible because the
bytecode is now a data structure that you can change. `push 1, push 2, add`
can become `push 3` before anything runs. This compiler does none of that, but
it could. That possibility is the reason that compiled code can run faster than
interpreted code, and not only because some of its work occurred earlier.

The next chapter is the virtual machine. The virtual machine runs the bytecode
that this compiler wrote.
