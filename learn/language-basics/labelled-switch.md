# Labelled Switch

> A switch that you can jump back into with a new value.

A `switch` can have a label, as a block or a loop can. When a switch has a label, two statements become available:

- `continue :label value` runs the switch again, with `value` as the new operand.
- `break :label value` leaves the switch, and the full switch has the value `value`.

With these two statements, you can write a state machine without a loop and without a state variable. This form came in Zig 0.14.

```zig
const std = @import("std");

const Tag = enum { identifier, number, equal, semicolon, invalid, eof };

const Token = struct { tag: Tag, start: usize, end: usize };

const State = enum { start, identifier, number };

// One token from `src`. The token starts at `index.*`.
//
// The source ends with a zero byte, as the source of std.zig.Tokenizer does.
// Thus the terminator marks the end of the input, and no prong checks a length.
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

// The same tokenizer in the form that was necessary before Zig 0.14: a loop
// around a switch, and a variable that holds the state.
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

// A small stack machine. The operand of each `continue` is the next
// instruction. The program knows the next instruction only at run time.
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

`State.start` is the first operand. Each prong is a state.

- `continue :state .identifier` means "go to the `.identifier` prong now".
- `break :state .equal` means "stop, and the answer is `.equal`".

The label is before `switch`. You can select any name for the label.

## See the jumps

The program above tokenizes `n2 = 40;`. Before each prong decides where to go, it prints its state and the byte that it examines.

- A line that starts with a state name is one entry into the switch.
- A line without an indent is a token that a `break` gives.

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

Read the first three lines:

1. `.start` sees `n`. A name can start with `n`, so `.start` continues into `.identifier`.
2. `.identifier` sees `2`. A name can contain `2`, so `.identifier` continues into itself.
3. Then `.identifier` sees a space and breaks with `.identifier`.

The tokenizer does not consume the space. The next call starts on the space, and `.start` continues into `.start` to skip it.

The source is a `[:0]const u8`. When the code reads one position after the last character, it gets the `0` terminator. Thus the `.start` prong ends the input when it matches `0`. It does not check a length.

`std.zig.Tokenizer` is the tokenizer that the Zig compiler uses on your code, and it has the same structure. Its `next` function is one labelled switch over a `State` enum, much larger than this one.

## What the labelled switch replaces

Before 0.14, the same tokenizer needed a loop around the switch. A variable held the state, and each transition had two steps. First the code set the variable, then the loop started its next iteration.

```zig
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
```

*Quoted from the source: `nextLoop` from `snippets/02-language/labelled-switch.zig`.*

The program runs the two versions on each token and checks that they agree:

```
loop form agrees: true
```

The two versions do the same thing. The language reference says this directly: a labelled switch has the same semantics as a `while (true)` around a `switch`. The difference is in how a person reads each version.

In the loop form, `state = .number;` is a line that sets a variable. To know that the line moves the machine, you must find the loop. You must also check that no code after the assignment runs before the next iteration.

In the labelled form, `continue :state .number` is the transition, and no code after it in the prong can run. Also, no `state` variable stays in scope, so other code cannot read or change the state.

## When the next state is only known at run time

The operand of `continue` does not have to be a literal. A bytecode interpreter selects the next prong from the next instruction:

```zig
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
```

*Quoted from the source: `run` from `snippets/02-language/labelled-switch.zig`.*

```
(2 + 3) * 4 = 20
```

`Instruction` is a tagged union. Thus `.push => |n|` captures the payload, as in a usual switch. `.halt` has no `continue`. Thus its value is the value of the full switch, and `run` returns that value.

The language reference gives this dispatch loop as the reason for the feature. The reason comes from code generation:

- When the operand of `continue` is known at compile time, as `.identifier` is, the compiler can change it into a direct jump to that prong.
- When the operand is known only at run time, as `code[ip]` is, each `continue` can get its own branch.

A loop sends each iteration through one shared dispatch point. The CPU then predicts that one branch for all instructions together. With a branch at each `continue`, the CPU can learn that another `.push` usually follows a `.push`. The CPU learns this separately from what follows `.mul`.

The language lets the compiler do these things. Measure if a given backend and optimization mode does them. Do not assume it.

## Two compile errors

`continue` on a switch needs a value. Without a value, the switch has no operand:

```
error: cannot continue switch without operand
```

A label that no statement uses is a compile error, as on a loop:

```
error: unused switch label
```

## Related

A labelled switch uses the same label syntax as [labelled blocks](https://www.ziglang.in/learn/language-basics/labelled-blocks/) and [labelled loops](https://www.ziglang.in/learn/language-basics/labelled-loops/).

All the rules of a usual [switch](https://www.ziglang.in/learn/language-basics/switch/) still apply, and exhaustiveness is one of them. If you add a tag to `State`, the tokenizer does not compile until a prong handles the new tag.
