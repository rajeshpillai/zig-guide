# A Virtual Machine

> Fetch, decode, execute. A loop over an array, with no tree.

The compiler produced an array of instructions. This chapter runs it, and the
program that does so is the smallest one in the section.

There is an instruction pointer, an index into the array. Read the instruction
it points at, move it forward, do what the instruction says, repeat. That loop
is called **fetch, decode, execute**. A physical processor runs the same loop,
so this program is called a virtual machine, not an interpreter.

Everything the machine needs is a stack and a table of slots. Instructions
never name their operands: they take them from the top of the stack and put
the result back.

## The program

```zig
const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("parser.zig");
const comp = @import("compiler.zig");

pub const Error = error{
    StackOverflow,
    StackUnderflow,
    DivideByZero,
    WriteFailed,
};

pub const Vm = struct {
    chunk: *const comp.Chunk,
    out: *std.Io.Writer,

    stack: [64]i64 = undefined,
    top: usize = 0,
    /// One value per slot the compiler allocated. Reading a variable is an
    /// array index now; the name it had is not present anywhere.
    globals: [32]i64 = @splat(0),
    /// Instructions executed, so the cost of the loop is visible.
    steps: usize = 0,

    fn push(vm: *Vm, value: i64) Error!void {
        if (vm.top == vm.stack.len) return error.StackOverflow;
        vm.stack[vm.top] = value;
        vm.top += 1;
    }

    fn pop(vm: *Vm) Error!i64 {
        if (vm.top == 0) return error.StackUnderflow;
        vm.top -= 1;
        return vm.stack[vm.top];
    }

    pub fn run(vm: *Vm) Error!void {
        // The instruction pointer is an index, not a pointer, and moving it is
        // the only control flow this machine has. A jump is an assignment.
        var ip: usize = 0;

        while (true) {
            const instr = vm.chunk.code[ip];
            ip += 1;
            vm.steps += 1;

            switch (instr.op) {
                .push => try vm.push(instr.arg),
                .load => try vm.push(vm.globals[@intCast(instr.arg)]),
                .store => vm.globals[@intCast(instr.arg)] = try vm.pop(),
                .neg => try vm.push(-(try vm.pop())),
                // Order matters: the right operand was pushed last, so it
                // comes off first. Getting this backwards makes `+` look
                // correct and `-` silently wrong.
                .add, .sub, .mul, .div, .lt, .eq => {
                    const right = try vm.pop();
                    const left = try vm.pop();
                    try vm.push(switch (instr.op) {
                        .add => left + right,
                        .sub => left - right,
                        .mul => left * right,
                        .div => if (right == 0) return error.DivideByZero else @divTrunc(left, right),
                        .lt => @intFromBool(left < right),
                        else => @intFromBool(left == right),
                    });
                },
                .print => try vm.out.print("{d}\n", .{try vm.pop()}),
                .jmp => ip = @intCast(instr.arg),
                .jmp_if_false => if (try vm.pop() == 0) {
                    ip = @intCast(instr.arg);
                },
                .halt => return,
            }
        }
    }
};

fn execute(source: []const u8, out: *std.Io.Writer) !usize {
    var tokens: [256]lex.Token = undefined;
    var nodes: [256]ast.Node = undefined;
    var code: [128]comp.Instr = undefined;

    var chunk: comp.Chunk = .{ .code = &code };
    try comp.compileSource(source, &tokens, &nodes, &chunk);

    var vm: Vm = .{ .chunk = &chunk, .out = out };
    try vm.run();
    return vm.steps;
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    try out.writeAll("source -> bytecode -> answer\n");
    const loop =
        \\let total = 0;
        \\while (total < 10) {
        \\  total = total + 3;
        \\}
        \\print total;
    ;
    const steps = try execute(loop, out);
    try out.print("{d} instructions executed\n", .{steps});

    // The same programs the tree-walking interpreter ran, for comparison.
    try out.writeAll("\nsum of squares 1..5\n");
    _ = try execute(
        \\let total = 0;
        \\let i = 1;
        \\while (i < 6) {
        \\  total = total + i * i;
        \\  i = i + 1;
        \\}
        \\print total;
        \\if (total == 55) { print 1; } else { print 0; }
    , out);

    try out.writeAll("\narithmetic\n");
    _ = try execute("print 1 + 2 * 3; print (1 + 2) * 3; print 1 - 2 - 3; print (0 - 7) / 2;", out);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.vm`)*

## What just happened

**The answers match the tree-walking interpreter exactly.** 55 and 1 for the
sum of squares, the same arithmetic results. Compiling and interpreting do
the same computation. The compiler only makes its decisions earlier. If the
answers differed, one of them would have a bug.

**A jump is an assignment.** `ip = instr.arg`, and that is the entire
implementation of `while`, `if` and `else`. All the structure the parser
found is gone. The tree became a flat array, and control flow is arithmetic on
an index. This is what "lowering" means. It is why a disassembly is hard to
read and fast to run.

**Operand order is an easy bug in this loop.** The right operand was pushed
last, so it must be popped first. If you get it backwards, `+` and `*` still
look correct, because order does not change their result. But `-` and `/`
give wrong answers with no error. A test
suite of `2 + 3` would pass.

**45 instructions for a five-line program.** The count is printed so you can
see the cost. Each instruction is one switch dispatch, and that is the cost of
a bytecode VM. Real VMs use computed goto or a JIT because this switch runs
billions of times.

Nothing in the running program knows a variable ever had a name. So a stripped
binary gives you a stack trace full of addresses. Debug information is a
separate thing you choose to keep.

## The state of this language

This VM has no `call` and no `ret`, so a program using functions compiles to
bytecode that silently leaves them out. This stays so for one more chapter. A calling convention is four separate decisions: where arguments
live, how a frame is addressed, who restores the instruction pointer, and who
cleans up the arguments. Each one has alternatives.

[A Calling Convention](https://www.ziglang.in/learn/tiny-lang/calls/) makes those decisions and runs
`fact(5)` through compiled bytecode. Read this VM first: the calling one is
the same dispatch loop with `load_local`, `call` and `ret` added, and `div`
and `neg` dropped.

## Check yourself

The VM checks for stack overflow and underflow on every push and pop. A real
one usually does not. Why is that safe?

Because the compiler is the one producing the bytecode, and it only emits
sequences that balance. `add` is only ever emitted after two operands, so a
correct compiler cannot produce an `add` that underflows. Real VMs move the
check to the moment bytecode is *loaded*, verifying it once rather than on
every instruction. The JVM's bytecode verifier exists to do this. The checks
are here because they are cheap at this size. Also, a hand-written bad chunk
should report an error, not read memory it does not own.

## If you have written C

The dispatch loop is a switch, and the standard trick to make it faster is
computed goto. It is a GCC extension where each instruction ends by jumping
directly to the next handler, instead of returning to the top of the switch.
It helps because the branch predictor gets one indirect jump per opcode
instead of one shared jump. It is a common optimisation in real interpreters.

The stack is the other difference. The VM here checks every push and pop. In
C, pushing past the end of the stack array reads and writes past it with no
complaint. This loop runs millions of times, so a bug there corrupts something
far away and shows up much later.

## Where to go next

That is the pipeline: characters to tokens, tokens to a tree, the tree walked
or lowered to instructions, and the instructions run. The compilers and
interpreters you use follow the same steps, with many more cases.

If you want to learn the machine under the language,
[Groundwork](https://www.ziglang.in/learn/systems-from-scratch/) covers what a byte, an address and
a stack frame actually are. If you would rather keep building tools, [the Unix
toolbox](https://www.ziglang.in/learn/unix-tools/) is seven more programs in the same spirit.
