# A Tree-Walking Interpreter

> Evaluate a node by evaluating its children.

After two stages, the source is a tree. In this chapter the tree runs, and
the code needed is smaller than the parser.

To evaluate `(+ 1 (* 2 3))`: it is a `+`, so evaluate its two children and add
them. The left child is `1`, which evaluates to itself. The right child is a
`*`, so evaluate *its* two children and multiply. There is no third rule. The
function calls itself once per child, so the recursion has the same shape as
the tree. It stops at numbers and names.

This is a **tree-walking interpreter**. Most languages start this way, and
several never needed anything else.

## Two kinds of node

The grammar already split expressions from statements, and the interpreter
keeps the same split:

- `eval` takes a node and returns an `i64`. Expressions produce values.
- `exec` takes a node and returns nothing. Statements produce effects.

Because they are separate, a statement can never be used as a value: `exec`
has nothing to return. The grammar stops `print` from appearing inside an
expression, so nothing has to check for that at run time.

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

/// Names to values. A flat array searched linearly, which is the right choice
/// at this size and the wrong one at a thousand: real interpreters resolve a
/// name to a slot number once, at compile time, so this search never happens
/// at run time.
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

    /// Expressions produce a value. Every case is: evaluate the children,
    /// then combine them. The recursion follows the shape of the tree
    /// exactly, which keeps this interpreter short.
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
                    // The language must define division by zero. The machine does not.
                    .slash => if (right == 0) error.DivideByZero else @divTrunc(left, right),
                    .lt => @intFromBool(left < right),
                    .eq => @intFromBool(left == right),
                    else => 0,
                };
            },
            else => 0,
        };
    }

    /// Statements produce an effect. `exec` returns nothing, which is the
    /// distinction the grammar already drew.
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

    // Integer division truncates toward zero, and dividing by zero is an
    // error the language defines rather than a crash it inherits.
    try out.writeAll("\ndivision\n");
    // The second one shows the difference: truncating toward zero
    // gives -3, where flooring would give -4.
    try run("print 7 / 2; print (0 - 7) / 2;", out);
    try report(out, "7 / 0", run("print 7 / 0;", out));

    // A name that was never defined is caught where it is used.
    try report(out, "print nope;", run("print nope;", out));

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.interpreter`)*

## What just happened

**`while` in the interpreted language is `while` in the interpreter.** Look at
the `.@"while"` case: it is a Zig loop whose body calls `exec`. The loop of the
language being run is borrowed from the language doing the running. The same
is true for `if`, and for recursion when the next chapter adds functions. This
defines a tree-walking interpreter, and it is also its main limitation: it can
only offer control flow the host language already has.

**Names are found by searching an array.** `Env` walks its list comparing
strings. That works at 32 variables and is too slow at a thousand, because
the search happens *every time a variable is read*, inside the loop. Real interpreters fix this by resolving each name to a slot number
once, before running, so at run time a variable read is an array index. The
compiler later in this section does exactly that: it emits `load` with a slot
number, and by then the name is gone.

**Division by zero is a choice the language makes.** The machine's divide
instruction traps, so the language has to say what division by zero means.
Here it is an error in the return type. It goes up through `try` and out of
`run` like any other error. Returning an error instead of crashing is the
choice [Errors Are Values](https://www.ziglang.in/learn/systems-from-scratch/errors-are-values/)
describes, now in a language you wrote.

**`(0 - 7) / 2` printed -3, not -4.** Truncation toward zero, because the
implementation used `@divTrunc`. Flooring would have given -4, and both are
reasonable: C and Zig truncate, Python floors. Arithmetic does not decide
this. Your language decides it. If you do not choose on purpose, you get
whatever the host language does.

**The undefined name was caught where it was used.** It was not caught at
parse time, because the parser never asked what names mean. To catch it
earlier, a language needs a separate pass between parsing and running. That
pass is called a resolver. For this kind of mistake, a "compile-time error"
means an error from the resolver.

## Check yourself

The `.let` and `.assign` cases do exactly the same thing. Should they?

No. This simplification causes a real bug. `let x = 1;` declares a variable.
`x = 1;` assigns to a variable that should already exist. As written,
assigning to an undeclared name silently creates it. So a typo in a variable
name becomes a new variable, not an error. This bug made JavaScript add
`"use strict"` and Visual Basic add `Option Explicit`. The fix is two lines:
`assign` should look the name up and fail if it is missing. The code here
leaves the bug in so you can see it.

## If you have written C

A tree-walking interpreter in C is the same recursive `switch`. There are two
differences, and you have seen both before.

C's `eval` has to return both the value and the error. The usual ways are a
sentinel value, an out-parameter, or a global error flag. With any of the
three, "divide by zero" can end up silently returning 0 or setting a flag
nobody checks. `Error!i64` makes the failure part of the return type,
so a caller that ignores it does not compile.

And the environment in C is a linked list of `{char *name; long value; struct
Env *next;}` allocated as you go. That works until you ask who frees it. The
version here is a fixed array inside the interpreter. It lives as long as the
interpreter, so there is nothing to free. This is the cheapest correct
design, but it stops working once the language has closures.

Next: functions, which is where the environment stops being one flat thing.
