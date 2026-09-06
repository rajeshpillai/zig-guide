# Functions and Frames

> A call needs somewhere to put its own variables, and a way to come back.

The interpreter so far has one set of variables. Adding functions breaks that
immediately. Two calls to the same function must not share one set of
variables, and a recursive call has to have several alive at once, each
belonging to a different call.

So a call needs its own storage. That is a **frame**, the run-time counterpart
of the machine-level idea in [The
Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/), except here you build it
yourself instead of the hardware providing it. Calling pushes one, returning
pops it, and the array of them is the call stack.

The second problem is subtler. `return` can appear anywhere: inside an `if`,
inside a `while`, inside a block inside both. It has to abandon all of that
and land back at the call site. The `exec` function is recursive, so `return`
needs to unwind an unknown number of Zig frames.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`17-tiny-lang.functions`)*

## What just happened

**`fact(5)` gave 120 and `fib(10)` gave 55**, which means several `n`s were
alive simultaneously and none of them interfered. `fib(10)` alone makes 177
calls, and each got a frame, used it, and gave it back.

**`bump(1)` printed 2 and the global `x` stayed 100.** The parameter is defined
in the new frame, so it shadows the global rather than overwriting it. Look at
`lookup`: current frame first, globals second, and nothing else. Two lines,
and they are the entire scoping rule of this language.

**`return` is implemented as an error.** `error.Return` is not a failure and
does not mean anything went wrong. It is the only mechanism Zig offers that
unwinds through an arbitrary depth of recursive calls. It is caught in exactly
one place: immediately after evaluating the body. Catching it nowhere else is
what turns it from an error into a jump to a known point.

This is a real technique rather than a hack, and interpreters written in
languages with exceptions do the same thing with a `ReturnException`. What
makes it safe here is that the error set is written out. The return signal is
visible in every signature that can produce it, and a caller that forgot to
handle it would not compile.

**Arguments are evaluated before the frame is pushed.** They have to be: they
are expressions in the *caller's* scope. Evaluating them after pushing would
let a parameter see the new, empty frame instead of the caller's. That is a
bug which produces plausible-looking wrong answers rather than a crash.

**The stack depth is 64 and the limit is enforced.** `loop(n)` calling itself
forever stops with `StackOverflow` rather than exhausting the host's stack and
taking the whole program down. That is the advantage of building your own call
stack: the limit is a number you chose and can report on, instead of a
segfault somewhere in the runtime.

## Check yourself

`fn` declarations are registered when the `fn` statement executes. What
happens if a function calls another one that is declared after it?

It works, as long as the *call* happens after both declarations have run. In
the program above, `fib` refers to itself, and that is fine because by the
time `print fib(10);` runs, the declaration has executed. But a program that
called `f()` at the top and declared `f` at the bottom would fail with
`UnknownFunction`. Languages that allow that do a separate pass to collect
declarations before running anything. It is called hoisting, and it is one
more thing a compiler does that an interpreter has to be told to do.

## If you have written C

C gives you the frame for free: locals live on the machine stack, and `return`
is an instruction. The work in this chapter is the work the C compiler is
doing for you. That is why writing an interpreter is a good way to understand
what your compiler emits.

Two comparisons worth drawing. C's stack depth is whatever the OS gave the
thread, and exceeding it is a segfault with no useful message, because nothing
is checking. The interpreter above checks on every call, which costs one
comparison and buys an error you can report with a line number.

And C's `return` genuinely unwinds nothing, because there is nothing to
unwind: the frame is popped by adjusting a register. The C equivalent of what
this chapter does is `setjmp`/`longjmp`. C programs use it for exactly this
shape of problem, and it comes with all the caveats about what is left in an
inconsistent state when you jump past it.

Next: a compiler, which stops walking the tree and starts emitting
instructions.
