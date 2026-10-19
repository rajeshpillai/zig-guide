//! title: A Tree-Walking Interpreter
//! To evaluate a node, evaluate its children and then combine the results.

const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("parser.zig");

pub const Error = error{
    UndefinedVariable,
    TooManyVariables,
    DivideByZero,
    WriteFailed,
};

/// Names to values, in a flat array with a linear search. At this size, the
/// array is the correct choice. At a thousand names, it is the wrong choice.
/// Real interpreters resolve a name to a slot number one time, at compile
/// time. Then this search never occurs at run time.
pub const Env = struct {
    names: [32][]const u8 = undefined,
    values: [32]i64 = undefined,
    count: usize = 0,

    fn find(env: *Env, name: []const u8) ?usize {
        for (env.names[0..env.count], 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return i;
        }
        return null;
    }

    fn define(env: *Env, name: []const u8, value: i64) Error!void {
        if (env.find(name)) |i| {
            env.values[i] = value;
            return;
        }
        if (env.count == env.names.len) return error.TooManyVariables;
        env.names[env.count] = name;
        env.values[env.count] = value;
        env.count += 1;
    }

    fn get(env: *Env, name: []const u8) Error!i64 {
        const i = env.find(name) orelse return error.UndefinedVariable;
        return env.values[i];
    }
};

pub const Interpreter = struct {
    nodes: []const ast.Node,
    env: Env = .{},
    out: *std.Io.Writer,

    /// Expressions produce a value. Each case does two steps: evaluate the
    /// children, then combine the results. The recursion follows the shape of
    /// the tree exactly, thus this interpreter is short.
    pub fn eval(vm: *Interpreter, index: u32) Error!i64 {
        const node = vm.nodes[index];
        return switch (node.kind) {
            .number => node.value,
            .variable => vm.env.get(node.name),
            .unary => -(try vm.eval(node.a.?)),
            .binary => blk: {
                const left = try vm.eval(node.a.?);
                const right = try vm.eval(node.b.?);
                break :blk switch (node.op) {
                    .plus => left + right,
                    .minus => left - right,
                    .star => left * right,
                    // The language must define division by zero. The machine does not define it.
                    .slash => if (right == 0) error.DivideByZero else @divTrunc(left, right),
                    .lt => @intFromBool(left < right),
                    .eq => @intFromBool(left == right),
                    else => 0,
                };
            },
            else => 0,
        };
    }

    /// Statements produce an effect. `exec` returns nothing. The grammar
    /// already made this distinction.
    pub fn exec(vm: *Interpreter, index: u32) Error!void {
        const node = vm.nodes[index];
        switch (node.kind) {
            .let, .assign => try vm.env.define(node.name, try vm.eval(node.a.?)),
            .print => try vm.out.print("{d}\n", .{try vm.eval(node.a.?)}),
            .@"if" => {
                if (try vm.eval(node.a.?) != 0) {
                    try vm.exec(node.b.?);
                } else if (node.c) |other| {
                    try vm.exec(other);
                }
            },
            // The loop in the interpreted language is a loop in the
            // interpreter. The interpreter has no other way to repeat code.
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
    var tokens: [256]lex.Token = undefined;
    var nodes: [256]ast.Node = undefined;
    const tree = try ast.parse(source, &tokens, &nodes);

    var interp: Interpreter = .{ .nodes = &nodes, .out = out };
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

    const program =
        \\let total = 0;
        \\let i = 1;
        \\while (i < 6) {
        \\  total = total + i * i;
        \\  i = i + 1;
        \\}
        \\print total;
        \\if (total == 55) { print 1; } else { print 0; }
    ;

    try out.writeAll("sum of squares 1..5\n");
    try run(program, out);

    // Integer division truncates toward zero. Division by zero is an error
    // that the language defines, not a crash that it gets from the host.
    try out.writeAll("\ndivision\n");
    // The second statement shows the difference. Truncation toward zero
    // gives -3, and floor division would give -4.
    try run("print 7 / 2; print (0 - 7) / 2;", out);
    try report(out, "7 / 0", run("print 7 / 0;", out));

    // The interpreter finds an undefined name at the point where the program uses it.
    try report(out, "print nope;", run("print nope;", out));

    try out.flush();
}
