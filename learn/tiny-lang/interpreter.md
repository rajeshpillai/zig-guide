# A Tree-Walking Interpreter

> To evaluate a node, evaluate its children and then combine the results.

After two stages, the source is a tree. In this chapter, the tree runs. The
code for this stage is smaller than the parser.

To evaluate `(+ 1 (* 2 3))`, start at the top. The node is a `+`, thus evaluate
its two children and add them. The left child is `1`, and its value is `1`. The
right child is a `*`, thus evaluate *its* two children and multiply them. There
is no third rule.

The function calls itself one time for each child, thus the recursion has the
same shape as the tree. The recursion stops at numbers and names.

This is a **tree-walking interpreter**. Most languages start this way, and some
languages never needed anything more.

## Two kinds of node

The grammar already separates expressions from statements, and the interpreter
keeps the same split:

- `eval` takes a node and returns an `i64`. Expressions produce values.
- `exec` takes a node and returns nothing. Statements produce effects.

Because the two functions are separate, you can never use a statement as a
value: `exec` has nothing to return. The grammar does not let `print` appear
inside an expression. Thus no code has to check for a `print` in an expression
at run time.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.interpreter`)*

## What just happened

**`while` in the interpreted language is `while` in the interpreter.** Look at
the `.@"while"` case. The case is a Zig loop, and the body of the loop calls
`exec`. The interpreted language gets its loop from Zig, the language of the
interpreter.

The same is true for `if`, and for recursion when the next chapter adds
functions. This property defines a tree-walking interpreter. It is also the
main limit of a tree-walking interpreter: it can only give the control flow
that the host language already has.

**The interpreter finds names with a search through an array.** `Env` compares
each string in its list with the name. This method works with 32 variables, and
it is too slow with a thousand. The reason is that the search occurs *each time
the program reads a variable*, also inside the loop.

Real interpreters solve this problem. Before the program runs, they resolve
each name to a slot number one time. Then a variable read at run time is an
array index. The compiler later in this section does exactly that. The compiler
emits `load` with a slot number, and at that point the name is gone.

**Division by zero is a choice that the language makes.** The divide
instruction of the machine traps. Thus the language must say what division by
zero means. Here, division by zero is an error in the return type. The error
passes through `try` and leaves `run`, the same as other errors. To return an
error and not crash is the choice that
[Errors Are Values](https://www.ziglang.in/learn/systems-from-scratch/errors-are-values/) describes,
now in a language that you wrote.

**`(0 - 7) / 2` printed -3, not -4.** The result truncates toward zero because
the implementation used `@divTrunc`, and floor division would give -4. Both answers
are reasonable: C and Zig truncate, and Python uses floor division. Your
language decides this question, not arithmetic. If you do not choose
intentionally, you get the behaviour of the host language.

**The interpreter found the undefined name at the point where the program used
it.** The parser did not find the error, because the parser does not ask what
names mean. To find the error earlier, a language needs a separate pass between
the parser and the run. That pass is called a resolver. For this type of
mistake, a "compile-time error" is an error from the resolver.

## Check yourself

The `.let` and `.assign` cases do exactly the same thing. Should the two cases
do the same thing?

No. This simplification causes a real bug. `let x = 1;` declares a variable.
`x = 1;` assigns to a variable that must already exist. In the code here, an
assignment to an undeclared name silently creates the name. Thus a typo in a
variable name makes a new variable, not an error.

This bug is the reason that JavaScript added `"use strict"` and Visual Basic
added `Option Explicit`. The fix is two lines: `assign` should find the name,
and fail if the name does not exist. The code here keeps the bug, so that you can
see it.

## If you know C

In C, a tree-walking interpreter is the same recursive `switch`. There are two
differences, and you saw both of them before.

In C, `eval` must return the value and the error. The usual methods are a
sentinel value, an out-parameter, or a global error flag. With each of the
three, "divide by zero" can silently return 0, or set a flag that nobody
checks. `Error!i64` makes the failure part of the return type. Thus a caller
that ignores the failure does not compile.

Also, in C the environment is a linked list of `{char *name; long value; struct
Env *next;}`. The program allocates each node when it needs the node. That
design works until you ask which code frees the list. The version here is a
fixed array inside the interpreter. The array lives as long as the
interpreter, thus there is nothing to free. This is the cheapest correct
design, but it stops working when the language gets closures.

The next chapter adds functions. With functions, the environment is no longer
one flat thing.
