# Labelled Switch

> A switch you can jump back into with a new value.

A `switch` can carry a label, the same way a block or a loop can.

Once it has one, `continue :label value` runs the switch again with `value` as the new operand.

`break :label value` leaves the switch, and the whole switch evaluates to `value`.

That pair is enough to write a state machine with no loop and no state variable.

The form arrived in Zig 0.14.

```zig
const std = @import("std");

const Tag = enum { identifier, number, equal, semicolon, invalid, eof };

const Token = struct { tag: Tag, start: usize, end: usize };

const State = enum { start, identifier, number };

// One token from `src`, starting at `index.*`.
//
// The source is zero-terminated, like the one std.zig.Tokenizer reads, so the
// terminator is the end-of-input byte and no prong checks a length.
fn next(src: [:0]const u8, index: *usize, out: *std.Io.Writer) !Token {
    var i = index.*;
    var start = i;

    const tag: Tag = state: switch (State.start) {
        .start => {
            try visit(out, "start", src, i);
            switch (src[i]) {
                0 => break :state .eof,
                ' ' => {
                    i += 1;
                    start = i;
                    continue :state .start;
                },
                'a'...'z', '_' => {
                    i += 1;
                    continue :state .identifier;
                },
                '0'...'9' => {
                    i += 1;
                    continue :state .number;
                },
                '=' => {
                    i += 1;
                    break :state .equal;
                },
                ';' => {
                    i += 1;
                    break :state .semicolon;
                },
                else => {
                    i += 1;
                    break :state .invalid;
                },
            }
        },
        .identifier => {
            try visit(out, "identifier", src, i);
            switch (src[i]) {
                'a'...'z', '_', '0'...'9' => {
                    i += 1;
                    continue :state .identifier;
                },
                else => break :state .identifier,
            }
        },
        .number => {
            try visit(out, "number", src, i);
            switch (src[i]) {
                '0'...'9' => {
                    i += 1;
                    continue :state .number;
                },
                else => break :state .number,
            }
        },
    };

    index.* = i;
    return .{ .tag = tag, .start = start, .end = i };
}

fn visit(out: *std.Io.Writer, state: []const u8, src: [:0]const u8, i: usize) !void {
    if (src[i] == 0) {
        try out.print("  {s:<10}  src[{d}] is the terminator\n", .{ state, i });
    } else {
        try out.print("  {s:<10}  src[{d}] = '{c}'\n", .{ state, i, src[i] });
    }
}

// The same tokenizer written the way it had to be before Zig 0.14: a loop
// around a switch, with the state kept in a variable.
fn nextLoop(src: [:0]const u8, index: *usize) Token {
    var i = index.*;
    var start = i;
    var state: State = .start;

    const tag: Tag = while (true) {
        switch (state) {
            .start => switch (src[i]) {
                0 => break .eof,
                ' ' => {
                    i += 1;
                    start = i;
                },
                'a'...'z', '_' => {
                    i += 1;
                    state = .identifier;
                },
                '0'...'9' => {
                    i += 1;
                    state = .number;
                },
                '=' => {
                    i += 1;
                    break .equal;
                },
                ';' => {
                    i += 1;
                    break .semicolon;
                },
                else => {
                    i += 1;
                    break .invalid;
                },
            },
            .identifier => switch (src[i]) {
                'a'...'z', '_', '0'...'9' => i += 1,
                else => break .identifier,
            },
            .number => switch (src[i]) {
                '0'...'9' => i += 1,
                else => break .number,
            },
        }
    };

    index.* = i;
    return .{ .tag = tag, .start = start, .end = i };
}

const Instruction = union(enum) {
    push: i32,
    add,
    mul,
    halt,
};

// A tiny stack machine. The operand of every `continue` is the next
// instruction, which is only known at run time.
fn run(code: []const Instruction) i32 {
    var stack: [8]i32 = undefined;
    var sp: usize = 0;
    var ip: usize = 0;

    return vm: switch (code[ip]) {
        .push => |n| {
            stack[sp] = n;
            sp += 1;
            ip += 1;
            continue :vm code[ip];
        },
        .add => {
            sp -= 1;
            stack[sp - 1] += stack[sp];
            ip += 1;
            continue :vm code[ip];
        },
        .mul => {
            sp -= 1;
            stack[sp - 1] *= stack[sp];
            ip += 1;
            continue :vm code[ip];
        },
        .halt => stack[sp - 1],
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const src: [:0]const u8 = "n2 = 40;";
    try out.print("source: \"{s}\"\n", .{src});

    var index: usize = 0;
    var loop_index: usize = 0;
    var agree = true;
    while (true) {
        const token = try next(src, &index, out);
        const again = nextLoop(src, &loop_index);
        if (!std.meta.eql(token, again)) agree = false;

        try out.print("{s} \"{s}\"\n", .{ @tagName(token.tag), src[token.start..token.end] });
        if (token.tag == .eof) break;
    }
    try out.print("loop form agrees: {}\n\n", .{agree});

    // (2 + 3) * 4
    const program = [_]Instruction{ .{ .push = 2 }, .{ .push = 3 }, .add, .{ .push = 4 }, .mul, .halt };
    try out.print("(2 + 3) * 4 = {d}\n", .{run(&program)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.labelled-switch`)*

## The shape

```zig
const tag: Tag = state: switch (State.start) {
    .start => switch (src[i]) {
        'a'...'z' => {
            i += 1;
            continue :state .identifier;
        },
        '=' => {
            i += 1;
            break :state .equal;
        },
        // ...
    },
    .identifier => switch (src[i]) {
        'a'...'z', '0'...'9' => {
            i += 1;
            continue :state .identifier;
        },
        else => break :state .identifier,
    },
};
```

`State.start` is the first operand.

Each prong is a state.

`continue :state .identifier` means "go to the `.identifier` prong now".

`break :state .equal` means "stop, and the answer is `.equal`".

The label goes before `switch`, and its name is up to you.

## Watching the jumps

The program above tokenizes `n2 = 40;`.

Every prong prints its state and the byte it is looking at before it decides where to go.

A line starting with a state name is one entry into the switch.

A line with no indent is a token coming out of a `break`.

```
source: "n2 = 40;"
  start       src[0] = 'n'
  identifier  src[1] = '2'
  identifier  src[2] = ' '
identifier "n2"
  start       src[2] = ' '
  start       src[3] = '='
equal "="
  start       src[4] = ' '
  start       src[5] = '4'
  number      src[6] = '0'
  number      src[7] = ';'
number "40"
  start       src[7] = ';'
semicolon ";"
  start       src[8] is the terminator
eof ""
```

Read the first three lines.

`.start` sees `n`, which can begin a name, so it continues into `.identifier`.

`.identifier` sees `2`, which can continue a name, so it continues into itself.

Then it sees a space and breaks with `.identifier`.

The space is not consumed.

The next call starts on it, and `.start` continues into `.start` to skip it.

The source is a `[:0]const u8`.

Reading one past the last character gives the `0` terminator, so the `.start` prong ends the input by matching `0` rather than checking a length.

`std.zig.Tokenizer`, the tokenizer the Zig compiler uses on your code, is written the same way.

Its `next` function is one labelled switch over a `State` enum, much larger than this one.

## What it replaces

Before 0.14 the same tokenizer needed a loop wrapped around the switch.

The state lived in a variable, and every transition was two steps: assign the variable, then let the loop come round.

<SnippetSource name="02-language.labelled-switch" decl="nextLoop" />

The program runs both versions on every token and checks they agree:

```
loop form agrees: true
```

The two do the same thing.

The language reference says so directly: a labelled switch is semantically a `while (true)` around a `switch`.

The difference is in how each one reads.

In the loop form, `state = .number;` is a line that sets a variable.

To know that it moves the machine, we need to find the loop, and check that nothing after the assignment runs before the loop comes round.

In the labelled form, `continue :state .number` is the transition, and nothing after it in the prong can run.

There is also no `state` variable left in scope for other code to read or change.

## When the next state is only known at run time

The operand of `continue` does not have to be a literal.

A bytecode interpreter picks the next prong from the next instruction:

<SnippetSource name="02-language.labelled-switch" decl="run" />

```
(2 + 3) * 4 = 20
```

`Instruction` is a tagged union, so `.push => |n|` captures the payload just as it does in an ordinary switch.

`.halt` has no `continue`, so its value is the value of the whole switch, which `run` returns.

The language reference gives this dispatch loop as the case that motivated the feature, and gives a reason from code generation.

When the operand of `continue` is known at compile time, as `.identifier` is, the compiler can lower it to a direct jump to that prong.

When it is known only at run time, as `code[ip]` is, each `continue` can get its own branch.

A loop sends every iteration through one shared dispatch point, and a CPU predicts that one branch for every instruction at once.

With a branch at each `continue`, the CPU can learn that `.push` is usually followed by another `.push`, separately from what follows `.mul`.

Those are things the compiler is allowed to do.

Whether a given backend and optimization mode does them is something to measure, not assume.

## Two compile errors

`continue` on a switch needs a value, because without one there is nothing to switch on:

```
error: cannot continue switch without operand
```

A label nothing refers to fails to build, as it does on a loop:

```
error: unused switch label
```

## Related

A labelled switch uses the same label syntax as [labelled blocks](https://www.ziglang.in/learn/language-basics/labelled-blocks/) and [labelled loops](https://www.ziglang.in/learn/language-basics/labelled-loops/).

Everything an ordinary [switch](https://www.ziglang.in/learn/language-basics/switch/) promises still holds, including exhaustiveness.

Add a tag to `State` and the tokenizer stops compiling until a prong handles it.
