# Functions and Frames

> A call needs a place for its own variables, and a way to return to the caller.

The interpreter so far has one set of variables. Functions break that design
immediately. Two calls to the same function must not share one set of
variables. A recursive call must have several sets alive at the same time, one
set for each call.

Thus a call needs its own storage, and that storage is a **frame**. A frame is
the run-time equivalent of the machine-level idea in
[The Stack](https://www.ziglang.in/learn/systems-from-scratch/the-stack/). The difference is that
here you build the frame yourself, and the hardware does not supply it. A call
pushes a frame, a return pops the frame, and the array of frames is the call
stack.

The second problem is less obvious. `return` can be anywhere: inside an `if`,
inside a `while`, or inside a block inside both. `return` must leave all of
those statements and arrive at the call site. The `exec` function is
recursive. Thus `return` must unwind an unknown number of Zig frames.

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
    /// Not a failure. `return` must leave all the nested blocks, loops and
    /// ifs around it. An error is the only mechanism that unwinds through any
    /// number of calls. This is the one place where this language uses an
    /// error for control flow, and exactly one caller catches it.
    Return,
};

/// The variables of one call. Frame 0 holds the globals. Thus the lookup
/// searches the current frame first and frame 0 second. Locals shadow
/// globals, and nothing else shadows anything.
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

    /// Declared functions, by name. Each `fn` statement adds its function when it executes.
    fn_names: [16][]const u8 = undefined,
    fn_nodes: [16]u32 = undefined,
    fn_count: usize = 0,

    /// The call stack, as an array. The depth limit here is intentional. The
    /// limit is a fixed number in the code, not the depth that the stack of
    /// the host allows.
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

        // The interpreter evaluates the arguments in the frame of the *caller*,
        // before the new frame exists. If you reverse the order, a parameter
        // can see the value that it will get.
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

        // A function that ends without a `return` gives 0. Only this code
        // catches `error.Return`. Thus `error.Return` is a jump to this exact
        // point, not a failure.
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

    // The parameter is a local. Thus it shadows the global with the same name,
    // and the global does not change when the call returns.
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

**`fact(5)` gave 120 and `fib(10)` gave 55.** Thus several values of `n` were
alive at the same time, and no value of `n` changed a different one. `fib(10)`
alone makes 177 calls. Each call got a frame, used the frame, and released
the frame.

**`bump(1)` printed 2, and the global `x` stayed 100.** The interpreter
defines the parameter in the new frame. Thus the parameter shadows the global, and does not
overwrite it. Look at `lookup`: it searches the current frame first, the
globals second, and nothing else. Those two lines are the complete rule for
scope in this language.

**`return` is an error in the implementation.** `error.Return` is not a
failure, and it does not mean that an operation failed. It is the only
mechanism in Zig that unwinds through recursive calls of any depth. Exactly one
place catches it: the code immediately after the body runs. Nothing else
catches `error.Return`, thus it works as a jump to a known point.

Interpreters use this method intentionally. Interpreters in languages with
exceptions do the same thing with a `ReturnException`. Here, the method is
safe because the error set is explicit. The return signal is visible in each
signature that can produce it. A caller that does not handle the signal does
not compile.

**The interpreter evaluates the arguments before it pushes the frame.** This
order is necessary, because the arguments are expressions in the scope of the
*caller*. If the interpreter evaluated them after the push, a parameter would
see the new, empty frame and not the frame of the caller. That bug does not
cause a crash. It gives wrong answers that look reasonable.

**The stack depth is 64, and the interpreter enforces the limit.** `loop(n)`
calls itself with no end, and stops with `StackOverflow`. It does not use all
of the stack of the host and crash the full program. This is the advantage of
your own call stack. The limit is a number that you chose and can report, not
a segfault somewhere in the runtime.

## Check yourself

The interpreter registers `fn` declarations when the `fn` statement executes.
What occurs if a function calls a function that you declare after it?

The call works if the call occurs after both declarations ran. In the program
above, `fib` refers to itself. This is correct, because the declaration already
ran when `print fib(10);` runs. But a program that calls `f()` at the top and
declares `f` at the bottom fails with `UnknownFunction`.

Languages that allow this order use a separate pass. The pass collects the
declarations before anything runs, and it is called hoisting. Hoisting is one
more thing that a compiler does and that you must tell an interpreter to do.

## If you know C

C makes the frame for you. Locals are on the machine stack, and `return` is an
instruction. The work in this chapter is the work that the C compiler does for
you. Thus an interpreter is a good way to understand what your compiler emits.

Compare two more things with C. In C, the stack depth is the size that the OS
gave the thread. If a program uses more than that size, the result is a
segfault with no useful message, because nothing checks the depth. The
interpreter above checks on each call. The check costs one comparison, and it
gives you an error that you can report with a line number.

Also, a C `return` unwinds nothing, because there is nothing to unwind: a
change to one register pops the frame. In C, the equivalent of this chapter is
`setjmp`/`longjmp`. C programs use these functions for exactly this type of
problem. They also have all the usual cautions: when you jump past code, that
code can leave its state inconsistent.

The next chapter is a compiler. The compiler emits instructions, and the
program does not walk the tree when it runs.
