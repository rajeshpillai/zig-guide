//! title: A Calling Convention
//! Where the arguments go, who cleans up, and how the machine finds its way back.

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
    /// The function being compiled, or null at the top level. Its parameters
    /// are the only names that resolve to a local slot.
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

    /// A parameter's slot is its position, counted from the frame base. That
    /// is the convention: the caller pushes the arguments, and the callee
    /// treats them as slots 0, 1, 2 without ever being told where they are.
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
            // Arguments are pushed by the caller, in order, and are simply
            // left on the stack. The callee's frame base points at the first
            // of them, so nothing has to be copied anywhere.
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
            // The body is emitted inline, with a jump around it, so that
            // running the program straight through does not fall into a
            // function nobody called.
            .fn_decl => {
                if (c.chunk.func_count == c.chunk.funcs.len) return error.TooManyFuncs;
                const over = try c.emit(.jmp, 0);

                var f: Func = .{ .name = node.name, .entry = c.chunk.len, .params = undefined, .param_count = 0 };
                var param = node.first;
                while (param) |p| : (param = c.nodes[p].next) {
                    f.params[f.param_count] = c.nodes[p].name;
                    f.param_count += 1;
                }
                // Registered before the body is compiled, so a function can
                // call itself.
                c.chunk.funcs[c.chunk.func_count] = f;
                c.chunk.func_count += 1;

                const saved = c.current;
                c.current = &c.chunk.funcs[c.chunk.func_count - 1];
                try c.compile(node.b.?);
                c.current = saved;

                // Falling off the end returns 0.
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
                // The call: remember where to come back to, and where this
                // frame's arguments start. Nothing is copied; the arguments
                // the caller pushed *are* the callee's locals.
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
                // The return: take the value, discard everything this call
                // put on the stack including its arguments, put the value
                // back, and jump home. Cleaning up the arguments is the
                // callee's job here, which is a choice the convention makes.
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
