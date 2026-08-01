//! title: Functions and Frames
//! A call needs somewhere to put its own variables, and a way to come back.

const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("parser.zig");

pub const Error = error{
    UndefinedVariable,
    UnknownFunction,
    WrongArgCount,
    TooManyVariables,
    DivideByZero,
    StackOverflow,
    WriteFailed,
    /// Not a failure. `return` has to unwind out of however many nested
    /// blocks, loops and ifs it sits inside, and an error is the only
    /// mechanism that walks back up through arbitrary calls. The one place
    /// this language uses an error for control flow, and it is caught by
    /// exactly one caller.
    Return,
};

/// One call's variables. Frame 0 is the globals, which is why a name is looked
/// up here first and there second: locals shadow, and nothing else does.
const Frame = struct {
    names: [16][]const u8 = undefined,
    values: [16]i64 = undefined,
    count: usize = 0,

    fn find(f: *Frame, name: []const u8) ?usize {
        for (f.names[0..f.count], 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return i;
        }
        return null;
    }

    fn define(f: *Frame, name: []const u8, value: i64) Error!void {
        if (f.find(name)) |i| {
            f.values[i] = value;
            return;
        }
        if (f.count == f.names.len) return error.TooManyVariables;
        f.names[f.count] = name;
        f.values[f.count] = value;
        f.count += 1;
    }
};

pub const Interpreter = struct {
    nodes: []const ast.Node,
    out: *std.Io.Writer,

    /// Declared functions, by name. Filled in as `fn` statements execute.
    fn_names: [16][]const u8 = undefined,
    fn_nodes: [16]u32 = undefined,
    fn_count: usize = 0,

    /// The call stack, as an array. Depth is bounded here on purpose: the
    /// limit is a number you can point at rather than whatever the host's
    /// stack happened to allow.
    frames: [64]Frame = undefined,
    depth: usize = 0,
    returned: i64 = 0,

    fn frame(vm: *Interpreter) *Frame {
        return &vm.frames[vm.depth];
    }

    fn lookup(vm: *Interpreter, name: []const u8) Error!i64 {
        if (vm.frame().find(name)) |i| return vm.frame().values[i];
        if (vm.frames[0].find(name)) |i| return vm.frames[0].values[i];
        return error.UndefinedVariable;
    }

    fn call(vm: *Interpreter, index: u32) Error!i64 {
        const node = vm.nodes[index];

        var found: ?u32 = null;
        for (vm.fn_names[0..vm.fn_count], 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, node.name)) found = vm.fn_nodes[i];
        }
        const decl_index = found orelse return error.UnknownFunction;
        const decl = vm.nodes[decl_index];

        // Arguments are evaluated in the *caller's* frame, before the new one
        // exists. Getting this backwards is how a parameter accidentally sees
        // the value it is about to be given.
        var args: [8]i64 = undefined;
        var count: usize = 0;
        var arg = node.first;
        while (arg) |a| : (arg = vm.nodes[a].next) {
            if (count == args.len) return error.WrongArgCount;
            args[count] = try vm.eval(a);
            count += 1;
        }

        if (vm.depth + 1 == vm.frames.len) return error.StackOverflow;
        vm.depth += 1;
        defer vm.depth -= 1;
        vm.frame().* = .{};

        var param = decl.first;
        var bound: usize = 0;
        while (param) |pa| : (param = vm.nodes[pa].next) {
            if (bound == count) return error.WrongArgCount;
            try vm.frame().define(vm.nodes[pa].name, args[bound]);
            bound += 1;
        }
        if (bound != count) return error.WrongArgCount;

        // A function that finishes without returning yields 0. `error.Return`
        // is caught here and nowhere else, which is what makes it a jump to
        // this exact point rather than a failure.
        vm.returned = 0;
        vm.exec(decl.b.?) catch |err| switch (err) {
            error.Return => {},
            else => return err,
        };
        return vm.returned;
    }

    pub fn eval(vm: *Interpreter, index: u32) Error!i64 {
        const node = vm.nodes[index];
        return switch (node.kind) {
            .number => node.value,
            .variable => vm.lookup(node.name),
            .call => vm.call(index),
            .unary => -(try vm.eval(node.a.?)),
            .binary => blk: {
                const left = try vm.eval(node.a.?);
                const right = try vm.eval(node.b.?);
                break :blk switch (node.op) {
                    .plus => left + right,
                    .minus => left - right,
                    .star => left * right,
                    .slash => if (right == 0) error.DivideByZero else @divTrunc(left, right),
                    .lt => @intFromBool(left < right),
                    .eq => @intFromBool(left == right),
                    else => 0,
                };
            },
            else => 0,
        };
    }

    pub fn exec(vm: *Interpreter, index: u32) Error!void {
        const node = vm.nodes[index];
        switch (node.kind) {
            .fn_decl => {
                if (vm.fn_count == vm.fn_names.len) return error.TooManyVariables;
                vm.fn_names[vm.fn_count] = node.name;
                vm.fn_nodes[vm.fn_count] = index;
                vm.fn_count += 1;
            },
            .ret => {
                vm.returned = if (node.a) |value| try vm.eval(value) else 0;
                return error.Return;
            },
            .let, .assign => try vm.frame().define(node.name, try vm.eval(node.a.?)),
            .print => try vm.out.print("{d}\n", .{try vm.eval(node.a.?)}),
            .@"if" => {
                if (try vm.eval(node.a.?) != 0) {
                    try vm.exec(node.b.?);
                } else if (node.c) |other| {
                    try vm.exec(other);
                }
            },
            .@"while" => while (try vm.eval(node.a.?) != 0) {
                try vm.exec(node.b.?);
            },
            .block => {
                var child = node.first;
                while (child) |c| : (child = vm.nodes[c].next) try vm.exec(c);
            },
            else => {},
        }
    }
};

fn run(source: []const u8, out: *std.Io.Writer) !void {
    var tokens: [512]lex.Token = undefined;
    var nodes: [512]ast.Node = undefined;
    const tree = try ast.parse(source, &tokens, &nodes);

    var interp: Interpreter = .{ .nodes = &nodes, .out = out };
    interp.frames[0] = .{};
    try interp.exec(tree.root);
}

fn report(out: *std.Io.Writer, label: []const u8, result: anyerror!void) !void {
    if (result) |_| {
        try out.print("{s} -> no error\n", .{label});
    } else |err| {
        try out.print("{s} -> {t}\n", .{ label, err });
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    try out.writeAll("recursion\n");
    try run(
        \\fn fact(n) {
        \\  if (n < 2) { return 1; }
        \\  return n * fact(n - 1);
        \\}
        \\fn fib(n) {
        \\  if (n < 2) { return n; }
        \\  return fib(n - 1) + fib(n - 2);
        \\}
        \\print fact(5);
        \\print fib(10);
    , out);

    // The parameter is a local, so it shadows the global of the same name and
    // the global is untouched when the call returns.
    try out.writeAll("\nshadowing\n");
    try run(
        \\let x = 100;
        \\fn bump(x) { return x + 1; }
        \\print bump(1);
        \\print x;
    , out);

    try out.writeAll("\nlimits\n");
    try report(out, "recursion with no base case", run("fn loop(n) { return loop(n); } print loop(1);", out));
    try report(out, "calling something undeclared", run("print nope(1);", out));
    try report(out, "too few arguments", run("fn two(a, b) { return a; } print two(1);", out));

    try out.flush();
}
