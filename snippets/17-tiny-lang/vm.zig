//! title: A Virtual Machine
//! Fetch, decode, execute. A loop over an array, and no tree in sight.

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
