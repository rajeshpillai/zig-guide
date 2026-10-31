# Talk to the Operating System

> Your program gets streams that it did not open, and it must return a status.

Each chapter before this one was about the inside of your program: its bytes,
its memory and its failures. This chapter is about the edge, because a program
cannot do anything from the inside alone. A program cannot read a file, write
to your terminal or open a connection. It can only calculate.

For each operation that goes outside the program, the program asks the
operating system. The name of that request is a **system call**. Your program
stops. The kernel does the operation, with privileges that your program does
not have. Then control returns to your program with a result.

That is the boundary, and all I/O goes across it.

The arrangement has three parts. It is older than almost all the other tools
that you use, and it did not change:

- The operating system gives your program some things when the program
  starts. The program does not ask for them.
- Your program asks for all other things by number. It uses a small integer,
  not a name, to refer to each thing that it opened.
- When the program ends, it gives back one number. The operating system
  guarantees only that number to the parent process.

## The program

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // Three streams were already open when main started. Nothing in this
    // program opened them, and the numbers are not random: each process starts
    // with the same three.
    try out.print("stdin  is descriptor {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout is descriptor {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr is descriptor {d}\n\n", .{std.Io.File.stderr().handle});

    // The streams go to different places. For this reason, there are two
    // output streams. This line is the result of the program.
    try out.writeAll("this line went to stdout: the program's output\n");
    try out.flush();

    // This line is for the person who watches. If you redirect the program
    // into a file, this line still shows on the terminal.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr: not part of the output\n");
    try err_writer.interface.flush();

    // A normal return from main gives a status of 0. By convention, 0 means
    // success. An error return makes the status non-zero. The operating system
    // guarantees only the status to the parent process.
    try out.writeAll("\nreturning from main reports success to whoever ran us\n");
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`15-groundwork.talking-to-the-os`)*

## What just happened

**Three streams were already open.** The program did not open them, and it
cannot select their numbers. Descriptor 0 is standard input, 1 is standard
output, and 2 is standard error. This is true for each process on each system
that comes from Unix. A shell uses this fact to connect two programs, and the
two programs do not have to agree on anything first.

**A descriptor is an integer and nothing else.** A descriptor is not a handle
object with methods inside it. It is a number. The kernel uses the number to
find the thing that you opened, in a table that the kernel keeps for your
process. When you open a file, you get the next free number.

This is the practical meaning of the phrase "everything is a file". A file, a
socket, a pipe and a terminal are all numbers into that table, and `read`
works on all of them.

**The program has two output streams, on purpose.** stdout is the *result* of
the program. If you pipe this program into a different program, the second
program reads these bytes. stderr is for the person who watches. You can see
the difference only when you redirect the output. Run the program on your
machine as `zig run talking-to-the-os.zig > out.txt`. The stdout lines go into
the file, but the stderr line still shows on your terminal. A tool that mixes
the two streams is difficult to use from scripts.

**The return from `main` reported 0.** A process ends with a status. By
convention, 0 means success, and each other value means a specific type of
failure. One small integer cannot hold much information. Thus programs also
write to stderr. The status says *that* the program failed. stderr says *what*
occurred.

## Check yourself

This program ran in your browser. The browser has no operating system, no
process table and no kernel to call. Then why did the descriptors print 0, 1
and 2?

The page runs the program under **WASI**. WASI is an interface with the same
shape as the real operating system: the same numbers and the same calls. But
WASI in the browser is JavaScript code, and it works with the browser, not
with a kernel.

The program cannot see the difference. An interface is exactly that promise.
Because of WASI, most of the snippets in this guide run on the page. Three
chapters in [the OS section](https://www.ziglang.in/learn/os/) need a real kernel: pipes, signals
and the start of new processes. Those chapters say so, and they do not have a
Run button.

## Where to go next

This chapter is the end of the track. You now have the model that the rest of
the guide assumes.

Perhaps you came here before the rest of the guide. Then [Getting
Started](https://www.ziglang.in/learn/getting-started/) installs a compiler, and shows how to run
these programs on your own machine. After that, [Language
Basics](https://www.ziglang.in/learn/language-basics/) teaches the same topics for the language: the
exact meaning of `*T`, how optionals remove null, and what `comptime` is.

If you already read those sections, go to [the operating system](https://www.ziglang.in/learn/os/)
next. That section uses the descriptors above to open files, start processes
and connect pipes. If you prefer to learn when you build something, [Data
Structures](https://www.ziglang.in/learn/data-structures/) starts with a linked list. A linked list
is the smallest program that makes you really answer the ownership question
from [chapter five](https://www.ziglang.in/learn/systems-from-scratch/who-owns-this-memory/).

## If you know C

You already know all of this, with the names `open`, `read`, `write`, `close`
and `exit`. A Zig `std.Io.File` is a descriptor and some flag bits. You can
make one from the number 1, and write to standard output with it. The [file
descriptors](https://www.ziglang.in/learn/os/file-descriptors/) chapter does exactly that.

You will see two differences immediately:

- A failed call returns an error. It does not set a global `errno`. Thus the
  error works with `try`, as all other errors do.
- The permission to do I/O comes as an argument. `main` receives an `init`,
  and the writers above come from `init.io`. Zig has no global `stdout` that a
  function can use. Thus a function that does not take an `Io` cannot touch
  the outside world without your knowledge.
