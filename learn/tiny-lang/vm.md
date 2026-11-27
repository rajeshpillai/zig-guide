# A Virtual Machine

> Fetch, decode, execute. A loop over an array, with no tree.

The compiler made an array of instructions. This chapter runs that array. The
program that runs the array is the smallest program in the section.

The machine has an instruction pointer, which is an index into the array. The
machine does these steps in a loop:

1. Read the instruction at the instruction pointer.
2. Move the instruction pointer forward.
3. Do what the instruction says.
4. Do the steps again.

This loop is called **fetch, decode, execute**. A physical processor runs the
same loop. Thus this program is called a virtual machine, not an interpreter.

The machine needs only a stack and a table of slots. Instructions never name
their operands. The instructions take the operands from the top of the stack,
and put the result back on the stack.

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
    /// One value for each slot that the compiler allocated. A variable read is
    /// now an array index. The name of the variable is not in the VM.
    globals: [32]i64 = @splat(0),
    /// The number of instructions that ran. It makes the cost of the loop visible.
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
        // The instruction pointer is an index, not a pointer. A change to the
        // index is the only control flow that this machine has. A jump is an
        // assignment.
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
                // Order is important. The code pushed the right operand last,
                // thus the VM pops it first. If you reverse the order, `+`
                // looks correct and `-` is silently wrong.
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

**The answers are exactly the same as the answers of the tree-walking
interpreter.** The sum of squares gives 55 and 1, and the arithmetic results
are the same. Compilation and interpretation do the same calculation. The
compiler only makes its decisions earlier. If the answers were different, one
of the two would have a bug.

**A jump is an assignment.** `ip = instr.arg` is the full implementation of
`while`, `if` and `else`. All the structure that the parser found is gone. The
tree became a flat array, and control flow is arithmetic on an index. This
change is the meaning of "lowering". It is the reason that a disassembly is
hard to read and fast to run.

**Operand order is an easy bug to make in this loop.** The code pushed the
right operand last, thus the loop must pop it first. If you reverse the order,
`+` and `*` still look correct, because the order does not change their result.
But `-` and `/` give wrong answers with no error. A test suite of `2 + 3`
would pass.

**45 instructions for a five-line program.** The program prints the count so
that you can see the cost. Each instruction is one dispatch through the
switch, and that is the cost of a bytecode VM. Real VMs use computed goto or a
JIT, because this switch runs billions of times.

Nothing in the program at run time knows that a variable ever had a name. Thus
a stack trace from a stripped binary is full of addresses. Debug information
is a separate thing that you choose to keep.

## The state of this language

This VM has no `call` and no `ret`. Thus a program that uses functions
compiles to bytecode without those functions, and no error tells you. This
limit stays for one more chapter. A calling convention is four separate
decisions, and each decision has alternatives:

- where the arguments are
- how the code addresses a frame
- which code restores the instruction pointer
- which code removes the arguments

[A Calling Convention](https://www.ziglang.in/learn/tiny-lang/calls/) makes those decisions, and runs
`fact(5)` through compiled bytecode. Read this VM first. The VM in that chapter
is the same dispatch loop, with `load_local`, `call` and `ret` added, and `div`
and `neg` removed.

## Check yourself

The VM checks for stack overflow and underflow on each push and pop. A real VM
usually does not. Why is that safe?

The compiler makes the bytecode, and the compiler emits only sequences that
balance. The compiler emits `add` only after two operands. Thus a correct
compiler cannot make an `add` that underflows. Real VMs move the check to the
time when they *load* the bytecode. They verify the bytecode one time, not on
each instruction. The JVM bytecode verifier exists for this purpose.

The checks are here because they are cheap at this size. Also, a bad chunk
that a person wrote manually should report an error. The chunk should not
read memory that the VM does not own.

## If you know C

The dispatch loop is a switch. The usual method to make it faster is computed
goto, which is a GCC extension. With computed goto, each instruction ends with
a direct jump to the next handler, and does not return to the top of the
switch. It helps because the branch predictor gets one indirect jump for each
opcode, not one shared jump. It is a common optimisation in real interpreters.

The stack is the other difference. The VM here checks each push and pop. In C,
a push past the end of the stack array reads and writes past the array, with
no warning. This loop runs millions of times. Thus a bug there corrupts data
far away, and the problem appears much later.

## Where to go next

That is the full pipeline:

1. Characters become tokens.
2. Tokens become a tree.
3. The interpreter walks the tree, or the compiler lowers the tree to
   instructions.
4. The VM runs the instructions.

The compilers and interpreters that you use follow the same steps, with many
more cases.

To learn about the machine under the language, read
[Groundwork](https://www.ziglang.in/learn/systems-from-scratch/). Groundwork explains what a byte, an
address and a stack frame are. To continue to build tools, read
[the Unix toolbox](https://www.ziglang.in/learn/unix-tools/), which has seven more programs of the
same type.
