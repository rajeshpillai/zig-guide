# A Calling Convention

> Where the arguments go, which side removes them, and how the machine returns to the caller.

The compiler and the VM stopped before functions. Calls are not difficult to
implement. But to implement them, you must answer four questions that have no
obvious answers. The set of answers is called a **calling convention**.

1. Where do the arguments go?
2. How does the callee find its own variables?
3. Where does the machine go when the function returns?
4. Which side removes the arguments after the call?

Each question has more than one answer, and real machines make different
choices. Code that uses one convention cannot call code that uses a different
convention. Thus you cannot link a library that uses a different convention.

## The answers in this convention

**The caller pushes the arguments on the stack, in order.** This answer is the
oldest and the simplest. Real machines put the first few arguments in
registers, because registers are faster. For example, the System V AMD64 ABI
passes the first six integer arguments in `rdi, rsi, rdx, rcx, r8, r9`.

**A local is a slot that the code counts from the frame base.** When a call
starts, the base points at the first argument that the caller pushed. Thus
parameter 0 is at base + 0. No code has to tell the callee where its arguments
are, because the arguments are already on the stack at its base. No code
copies the arguments.

**The call saves the return address.** The instruction pointer already points
past the `call` when the VM pushes the frame. Thus the save costs no extra
work.

**The callee removes the arguments.** On `ret`, the callee resets the top of
the stack to the frame base, which discards the arguments. Then the callee
pushes the result. The other choice is that the caller removes the arguments,
and C uses that choice. C does this because of variadic functions: `printf`
cannot remove arguments when nothing tells it how many there are.

## The program

```zig
const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("parser.zig");

pub const Op = enum {
    push,
    load, // global slot
    store, // global slot
    load_local, // slot relative to the frame base
    add,
    sub,
    mul,
    lt,
    eq,
    print,
    jmp,
    jmp_if_false,
    call, // arg = function index
    ret,
    halt,
};

pub const Instr = struct { op: Op, arg: i64 = 0 };

const Func = struct { name: []const u8, entry: u32, params: [4][]const u8, param_count: u8 };

pub const Error = error{ TooMuchCode, TooManySlots, TooManyFuncs, UnknownFunction, WriteFailed };

pub const Chunk = struct {
    code: [256]Instr = undefined,
    len: u32 = 0,
    globals: [16][]const u8 = undefined,
    global_count: u32 = 0,
    funcs: [8]Func = undefined,
    func_count: u32 = 0,
};

const Compiler = struct {
    nodes: []const ast.Node,
    chunk: *Chunk,
    /// The function that the compiler compiles now, or null at the top level.
    /// Its parameters are the only names that resolve to a local slot.
    current: ?*const Func = null,

    fn emit(c: *Compiler, op: Op, arg: i64) Error!u32 {
        if (c.chunk.len == c.chunk.code.len) return error.TooMuchCode;
        c.chunk.code[c.chunk.len] = .{ .op = op, .arg = arg };
        c.chunk.len += 1;
        return c.chunk.len - 1;
    }

    fn globalSlot(c: *Compiler, name: []const u8) Error!i64 {
        for (c.chunk.globals[0..c.chunk.global_count], 0..) |g, i| {
            if (std.mem.eql(u8, g, name)) return @intCast(i);
        }
        if (c.chunk.global_count == c.chunk.globals.len) return error.TooManySlots;
        c.chunk.globals[c.chunk.global_count] = name;
        c.chunk.global_count += 1;
        return @intCast(c.chunk.global_count - 1);
    }

    /// The slot of a parameter is its position, counted from the frame base.
    /// That rule is the convention. The caller pushes the arguments, and the
    /// callee uses them as slots 0, 1, 2. Nothing tells the callee where they are.
    fn localSlot(c: *Compiler, name: []const u8) ?i64 {
        const f = c.current orelse return null;
        for (f.params[0..f.param_count], 0..) |p, i| {
            if (std.mem.eql(u8, p, name)) return @intCast(i);
        }
        return null;
    }

    fn funcIndex(c: *Compiler, name: []const u8) Error!i64 {
        for (c.chunk.funcs[0..c.chunk.func_count], 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        }
        return error.UnknownFunction;
    }

    fn compile(c: *Compiler, index: u32) Error!void {
        const node = c.nodes[index];
        switch (node.kind) {
            .number => _ = try c.emit(.push, node.value),
            .variable => {
                if (c.localSlot(node.name)) |slot| {
                    _ = try c.emit(.load_local, slot);
                } else {
                    _ = try c.emit(.load, try c.globalSlot(node.name));
                }
            },
            .binary => {
                try c.compile(node.a.?);
                try c.compile(node.b.?);
                _ = try c.emit(switch (node.op) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .lt => .lt,
                    else => .eq,
                }, 0);
            },
            // The caller pushes the arguments in order, and they stay on the
            // stack. The frame base of the callee points at the first argument.
            // Thus no code copies the arguments.
            .call => {
                var arg = node.first;
                while (arg) |a| : (arg = c.nodes[a].next) try c.compile(a);
                _ = try c.emit(.call, try c.funcIndex(node.name));
            },
            .let, .assign => {
                try c.compile(node.a.?);
                _ = try c.emit(.store, try c.globalSlot(node.name));
            },
            .print => {
                try c.compile(node.a.?);
                _ = try c.emit(.print, 0);
            },
            .ret => {
                if (node.a) |value| try c.compile(value) else _ = try c.emit(.push, 0);
                _ = try c.emit(.ret, 0);
            },
            .@"if" => {
                try c.compile(node.a.?);
                const skip = try c.emit(.jmp_if_false, 0);
                try c.compile(node.b.?);
                if (node.c) |other| {
                    const over = try c.emit(.jmp, 0);
                    c.chunk.code[skip].arg = c.chunk.len;
                    try c.compile(other);
                    c.chunk.code[over].arg = c.chunk.len;
                } else {
                    c.chunk.code[skip].arg = c.chunk.len;
                }
            },
            // The body is inline, with a jump around it. Thus a run straight
            // through the program does not go into a function that no code
            // called.
            .fn_decl => {
                if (c.chunk.func_count == c.chunk.funcs.len) return error.TooManyFuncs;
                const over = try c.emit(.jmp, 0);

                var f: Func = .{ .name = node.name, .entry = c.chunk.len, .params = undefined, .param_count = 0 };
                var param = node.first;
                while (param) |p| : (param = c.nodes[p].next) {
                    f.params[f.param_count] = c.nodes[p].name;
                    f.param_count += 1;
                }
                // The compiler registers the function before it compiles the
                // body. Thus a function can call itself.
                c.chunk.funcs[c.chunk.func_count] = f;
                c.chunk.func_count += 1;

                const saved = c.current;
                c.current = &c.chunk.funcs[c.chunk.func_count - 1];
                try c.compile(node.b.?);
                c.current = saved;

                // A function that gets to the end without a `return` gives 0.
                _ = try c.emit(.push, 0);
                _ = try c.emit(.ret, 0);
                c.chunk.code[over].arg = c.chunk.len;
            },
            .block => {
                var child = node.first;
                while (child) |ch| : (child = c.nodes[ch].next) try c.compile(ch);
            },
            else => {},
        }
    }
};

const Frame = struct { return_ip: u32, base: usize, args: usize };

pub const Vm = struct {
    chunk: *const Chunk,
    out: *std.Io.Writer,
    stack: [128]i64 = undefined,
    top: usize = 0,
    globals: [16]i64 = @splat(0),
    frames: [32]Frame = undefined,
    depth: usize = 0,
    steps: usize = 0,

    fn push(vm: *Vm, v: i64) !void {
        if (vm.top == vm.stack.len) return error.StackOverflow;
        vm.stack[vm.top] = v;
        vm.top += 1;
    }

    fn pop(vm: *Vm) !i64 {
        if (vm.top == 0) return error.StackUnderflow;
        vm.top -= 1;
        return vm.stack[vm.top];
    }

    pub fn run(vm: *Vm) !void {
        var ip: u32 = 0;
        while (true) {
            const instr = vm.chunk.code[ip];
            ip += 1;
            vm.steps += 1;

            switch (instr.op) {
                .push => try vm.push(instr.arg),
                .load => try vm.push(vm.globals[@intCast(instr.arg)]),
                .store => vm.globals[@intCast(instr.arg)] = try vm.pop(),
                .load_local => try vm.push(vm.stack[vm.frames[vm.depth - 1].base + @as(usize, @intCast(instr.arg))]),
                .add, .sub, .mul, .lt, .eq => {
                    const r = try vm.pop();
                    const l = try vm.pop();
                    try vm.push(switch (instr.op) {
                        .add => l + r,
                        .sub => l - r,
                        .mul => l * r,
                        .lt => @intFromBool(l < r),
                        else => @intFromBool(l == r),
                    });
                },
                .print => try vm.out.print("{d}\n", .{try vm.pop()}),
                .jmp => ip = @intCast(instr.arg),
                .jmp_if_false => if (try vm.pop() == 0) {
                    ip = @intCast(instr.arg);
                },
                // The call: remember the return address, and the start of the
                // arguments for this frame. No code copies the arguments. The
                // arguments that the caller pushed *are* the locals of the callee.
                .call => {
                    const f = vm.chunk.funcs[@intCast(instr.arg)];
                    if (vm.depth == vm.frames.len) return error.StackOverflow;
                    vm.frames[vm.depth] = .{
                        .return_ip = ip,
                        .base = vm.top - f.param_count,
                        .args = f.param_count,
                    };
                    vm.depth += 1;
                    ip = f.entry;
                },
                // The return: take the value, and discard the arguments and all
                // else that this call put on the stack. Then push the
                // value and jump to the caller. Here the callee removes the
                // arguments, because this calling convention chose that.
                .ret => {
                    const value = try vm.pop();
                    const frame = vm.frames[vm.depth - 1];
                    vm.depth -= 1;
                    vm.top = frame.base;
                    try vm.push(value);
                    ip = frame.return_ip;
                },
                .halt => return,
            }
        }
    }
};

fn compileSource(source: []const u8, tokens: []lex.Token, nodes: []ast.Node, chunk: *Chunk) !void {
    const tree = try ast.parse(source, tokens, nodes);
    var c: Compiler = .{ .nodes = nodes, .chunk = chunk };
    try c.compile(tree.root);
    _ = try c.emit(.halt, 0);
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var tokens: [512]lex.Token = undefined;
    var nodes: [512]ast.Node = undefined;
    var chunk: Chunk = .{};

    const source =
        \\fn square(n) { return n * n; }
        \\fn fact(n) {
        \\  if (n < 2) { return 1; }
        \\  return n * fact(n - 1);
        \\}
        \\print square(7);
        \\print fact(5);
    ;

    try compileSource(source, &tokens, &nodes, &chunk);

    try out.print("{d} instructions, {d} functions\n", .{ chunk.len, chunk.func_count });
    for (chunk.funcs[0..chunk.func_count]) |f| {
        try out.print("  {s} takes {d}, entry at {d}\n", .{ f.name, f.param_count, f.entry });
    }

    try out.writeAll("\nsquare's body\n");
    const square = chunk.funcs[0];
    for (chunk.code[square.entry .. square.entry + 5], square.entry..) |instr, i| {
        try out.print("  {d:0>3}  {t: <11} {d}\n", .{ i, instr.op, instr.arg });
    }

    try out.writeAll("\noutput\n");
    var vm: Vm = .{ .chunk = &chunk, .out = out };
    try vm.run();
    try out.print("\n{d} instructions executed\n", .{vm.steps});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.calls`)*

## What just happened

**The body of `square` is four instructions:** `load_local 0` two times, `mul`
and `ret`. Each function gets an epilogue, and the `push 0` after the body in
the listing is that epilogue. The epilogue is for the case where control
reaches the end of the function without a `return`. The body has no name
lookup and copies no arguments. The compiler made the parameter `n` into slot
0, thus at run time a read of `n` is one array index from the frame base.

**`fact(5)` recursed through compiled bytecode and gave 120.** Each call pushed
a frame, and each `ret` popped one. The recursion works because each call has
its own frame base. Five frames existed at the same time, at different stack
offsets. The frames chapter showed the same thing in the tree-walking
interpreter.

**A jump goes around each function body.** The compiler emits each body
inline, in the middle of the program. Without the jump, a straight run through
the program would go into `square`, although no code called `square`. The
compiler patches the jump when it knows the length of the body. This is the
same backpatching that the compiler chapter used for `if`.

**The compiler registers the function before it compiles the body.** This
order makes recursion possible. When the compiler gets to `fact(n - 1)` inside
`fact`, the compiler must already know that `fact` exists.

## Check yourself

The compiler resolves a name to a local slot only if the name is a parameter
of the function around it. What occurs with `let x = 1;` inside a function
body?

The variable becomes a **global**, and all calls share it. That is wrong, and
it is one of the limits that this compiler still has. The same silent `else`
prong drops `while` loops, and compiles `/` as an equality test.

Real locals need a scope resolver. The resolver walks the body first, collects
each declaration, and gives each declaration a slot above the parameters. The
frame then has space for both. The base pointer addresses all of the frame in
the same way.

With that resolver, a function has its own scope, not only arguments. The
resolver is the next thing to build if you continue this work. Without the
resolver, the tree-walking interpreter and this compiler still accept
different programs. A language with two back ends often has gaps like this.

## If you know C

You saw the output of this convention each time you read a disassembly. The
prologue and epilogue that GCC emits are exactly the bookkeeping above:

```
push rbp          ; save the caller's frame pointer
mov  rbp, rsp     ; this frame's base
sub  rsp, 32      ; room for locals
...
leave             ; undo it
ret               ; jump back
```

`rbp` is the frame base. A local at `[rbp-8]` is the slot arithmetic above,
and a real register does the work. A debugger can print a stack trace because
each frame stores the previous frame pointer. The debugger follows that chain
and gets the call history. The chain is the frame array from this chapter,
stored as a linked list in memory.

The convention is also the reason that a stack overflow in C is a segfault, not
an error. Nothing checks the depth, because a check would cost an instruction
on each call. This VM checks. The cost is acceptable here, because the VM
already pays for a dispatch through the switch.

If you did not read [the virtual machine chapter](https://www.ziglang.in/learn/tiny-lang/vm/), read
it next. This chapter uses the same dispatch loop, with `load_local`, `call`
and `ret` added, and `div` and `neg` removed.
