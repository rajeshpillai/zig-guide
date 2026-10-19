/**
 * Everything a search engine or a link preview reads about this site, in one
 * place. `Base.astro`, the sitemap, `robots.txt` and the section index pages
 * all read from here, so a title and the canonical URL that advertises it can
 * never drift apart.
 */

export const SITE_NAME = "Zig Guide Live";

export const SITE_DESCRIPTION =
  "A Zig tutorial and cookbook. Each build compiles and runs every snippet " +
  "against current Zig master, and the snippets run in your browser as WebAssembly.";

export const AUTHOR = "Rajesh Pillai";

/**
 * The one address a reader can write to. Plain text in a `mailto:`, not
 * assembled by a script: this is the only direct route to a person on a site
 * with no server to receive a form, so it has to work with JS off and has to
 * be readable by anything that fetches the page rather than renders it.
 */
export const AUTHOR_EMAIL = "pillai.rajesh@gmail.com";

/**
 * The repository this guide is written in.
 *
 * One constant, because three things point at it: the footer link, the source
 * link on every block of game code, and anything added later. A repository that
 * moves and leaves two of the three behind is the sort of breakage nothing on
 * this site would notice.
 */
export const REPO_URL = "https://github.com/rajeshpillai/zig-guide";

/** Path of the social preview card, relative to the site root. */
export const OG_IMAGE = "og.png";

/**
 * Copy for the index page of each section, keyed by its directory (which is
 * also its URL namespace). Without this a section index read "8 chapters."
 * and nothing else, which is the wrong page to leave empty: `/graphics/` is
 * what a reader searching for Zig graphics lands on, and a bare list of links
 * tells neither them nor a crawler what the section covers.
 *
 * `seoTitle` is the <title> only. The visible heading stays `title`, so the
 * page still reads as a chapter list rather than as a keyword line.
 */
export interface SectionMeta {
  seoTitle: string;
  description: string;
  /** Shown under the heading on the section index page. */
  lede: string;
  /**
   * The few things worth keeping from the section, stated on its index page
   * above the chapter list. Not a summary of the lede: each one should be a
   * claim a reader can carry away and check, and preferably one that corrects
   * something they arrived believing. Three to five, or leave it out.
   */
  takeaways?: string[];
  /**
   * A caveat about the section's programs, stated above the chapter list.
   *
   * Separate from `lede` because it is not a description of what the section
   * covers: it is a limit on how the code should be read. A section whose
   * snippets are cut down to make an idea visible needs to say so once, in the
   * place a reader decides what the section is for, rather than hedge in every
   * chapter and end up saying it nowhere with any weight.
   */
  note?: string;
  /**
   * A table from what a problem says to the chapter that solves it, shown on
   * the index page above the chapter list.
   *
   * Chapters are named by content id (`competitive-programming/two-pointers`)
   * and resolved against the collection at build time, so a renamed chapter
   * fails the build rather than leaving a dead row. A row may point outside
   * the section: linking the existing Priority Queue chapter is the point,
   * since re-teaching it here would put two pages in front of one search.
   */
  clues?: { says: string; chapters: string[] }[];
}

export const SECTIONS: Record<string, SectionMeta> = {
  "systems-from-scratch": {
    seoTitle: "Systems Programming from Scratch, in Zig",
    description:
      "Systems programming from zero: bytes and types, overflow, addresses, the " +
      "stack, memory ownership, struct layout, errors and system calls.",
    lede:
      "This section teaches systems programming from zero, with Zig instead of " +
      "C. Each chapter asks one question and answers the question in plain " +
      "terms. Then the chapter gives you a complete program that proves the " +
      "answer. If you know C, the last part of each page shows how to write the " +
      "same idea in C. If you do not know C, you do not need it here. The " +
      "chapters follow the order of a C course, and no earlier part of the " +
      "guide is necessary, so you can read this section at any time, also first.",
    takeaways: [
      "A type is not a property of the bytes. A type is an agreement about how to read the bytes. You can read the same four bytes in two ways, with no conversion.",
      "`u8` and `u32` are not two styles for one number. The two types use different amounts of memory. For a million values, the difference is three million bytes.",
      "An address is an ordinary number. `@intFromPtr` does no work. It shows you the number that the pointer already contained.",
      "When a function returns, the memory of its local variables becomes free, and the next call gets the same bytes. The reuse of those bytes makes a dangling pointer. The pointer itself did not change.",
      "Undefined behaviour is not a crash and not a garbage value. Undefined behaviour is a promise that you made to the compiler. If you break that promise, code in a different part of the program can change.",
    ],
  },
  terminal: {
    seoTitle: "Terminal Basics in Zig: String and Shell Primitives",
    description:
      "The primitives that a shell needs: string length, comparison, copy and " +
      "trim written by hand, a command-line tokenizer, and the read-eval-print loop.",
    lede:
      "Before a shell can run a command, the shell must measure, compare and " +
      "copy strings. A copy must not write past the end of the buffer. The " +
      "shell must also split a line into arguments, and loop until the user " +
      "or the input stops. This section has three chapters. Each chapter " +
      "builds one primitive by hand, and does not import it. The parts that " +
      "need a real kernel (fork, exec and pipes) are in the operating system " +
      "section.",
    takeaways: [
      "`strlen` walks the string each time that you call it. That cost is the reason why a slice stores its length.",
      "A buffer for a 5-byte string needs 6 bytes. A bounds check that forgets the terminator passes a quick test, and then the copy writes one byte past the end.",
      "A trim returns a view, not a copy. You do not need to move bytes to remove spaces.",
      "A REPL has two exits, not one. If a loop only looks for `quit`, the loop runs forever when a user presses Ctrl-D.",
    ],
  },
  "unix-tools": {
    seoTitle: "Build the Unix Tools in Zig: cat, wc, grep, sort, cut, printf, make",
    description:
      "Rebuild the standard Unix tools in Zig: cat, wc, grep, sort, cut, printf " +
      "and make. Each chapter is one complete program that runs in the page.",
    lede:
      "This section rebuilds seven tools that you use every day, from zero. " +
      "Each chapter is one complete program and teaches one technique. The " +
      "first four techniques are streaming reads, a state machine, search, and " +
      "ownership of the lines that you sort. The other three are a split on a " +
      "delimiter, the conversion of a number to text, and the decision about " +
      "what to rebuild. The tools are small enough that you can understand them " +
      "completely. They are also old enough that their design is the lesson.",
    takeaways: [
      "`cat` is a loop around a fixed buffer. The buffer size is a decision about memory, not about correctness. Thus `cat` can copy a file that is larger than memory.",
      "`wc` counts the transitions into a word, not the words. The counter is a state machine, and thus spaces at the start and double spaces cost nothing.",
      "To sort lines, you must own the lines. When the sorted output must live longer than the read buffer, you must decide who allocates.",
      "`printf` builds its digits backwards. Division is the only way to get the last digit of a number, and division gives the digits in reverse order.",
      "`make` is a topological sort over a graph of file timestamps. All the other parts of `make` are syntax.",
    ],
  },
  "web-server": {
    seoTitle: "Build an HTTP Server in Zig, from the Bytes Up",
    description:
      "Parse an HTTP request by hand, format a response, and send it over a real " +
      "socket. HTTP is text, a blank line ends the headers, and you need no framework.",
    lede:
      "HTTP is a text protocol. HTTP is simple enough to implement in an " +
      "afternoon, and strict enough that the details are important. These " +
      "chapters parse a request into a method, a target and headers. Then the " +
      "chapters put a socket in front of the parser and answer a real client. " +
      "The parser runs in this page. The server binds a port, so the server " +
      "runs on the build machine, and CI checks what the client received.",
    takeaways: [
      "HTTP does not declare a length at the start, so a server reads until it finds a blank line. The blank-line rule is all of the framing.",
      "Header names are case-insensitive. An exact comparison works with your own client, and fails with a proxy that another person wrote.",
      "If a response has no Content-Length, the client continues to wait, because nothing else tells the client that the body ended.",
      "The parser never needs a socket. The parser takes bytes and returns a request. Thus you can test, fuzz and run the same code on a page that has no network.",
    ],
  },
  storage: {
    seoTitle: "Build a Database in Zig: Logs, Locks and Indexes",
    description:
      "How storage engines work: an append-only log, the lost update from two " +
      "writers, indexes that change a scan to a lookup, and a crash-safe write-ahead log.",
    lede:
      "Every database is a file, plus rules. The rules keep the file correct " +
      "when two programs use it at the same time, and when the power fails. " +
      "These chapters build those rules from zero: append-only records, a " +
      "lock, an index, and a log. The program writes the log before the change " +
      "that the log describes.",
    takeaways: [
      "An append-only file cannot delete. To remove a value, you add a record. Thus every log-structured store has tombstones.",
      "Read, modify, write is three steps. The other writer can change the data in the gap between the first step and the third step.",
      "A race can give a different answer on each run. That property makes a race expensive to find, but it does not make a race rare.",
      "An index does not make the data smaller. An index adds a second structure, and you must keep the two structures consistent.",
    ],
  },
  browser: {
    seoTitle: "Build a Browser in Zig: Parse HTML, Match CSS, Lay Out, Render",
    description:
      "The pipeline behind each web page: an HTML parser that cannot fail, CSS " +
      "matching, a layout engine that makes boxes, and a renderer that makes pixels.",
    lede:
      "A browser is four programs in a sequence, and you can understand each " +
      "program alone. Bytes become a tree. A stylesheet decides the appearance " +
      "of each node. The tree becomes rectangles with positions, and the " +
      "rectangles become pixels. The script engine at the end is the language " +
      "from an earlier section of this track, applied to a document.",
    takeaways: [
      "By design, HTML has no parse errors. Each malformed document has a defined tree. The reason is that the first browsers had to render the web that already existed.",
      "A void element is complete by itself. If the parser treats `<br>` as an unclosed tag, the parser puts the rest of the page inside the `<br>`.",
      "Layout is two passes, not one. Widths go from the parent to the children. Heights are the sum of the children.",
      "The cascade is a sort: first by specificity, then by order. The last rule wins.",
    ],
  },
  "tiny-lang": {
    seoTitle: "Write a Programming Language in Zig",
    description:
      "Build a small language from zero: a lexer, a recursive descent parser, a " +
      "tree-walking interpreter, call frames, a bytecode compiler and a VM.",
    lede:
      "This section builds a language with variables, arithmetic, conditionals " +
      "and loops, one stage at a time. Each chapter takes the output of the " +
      "previous chapter. Characters become tokens, and tokens become a tree. " +
      "An interpreter walks the tree. Then a compiler changes the same tree to " +
      "bytecode for a stack machine. No part needs a kernel, so all of the " +
      "parts run in this page.",
    takeaways: [
      "A lexer is one pass with one character of lookahead. The lexer removes the whitespace, so no later stage must think about whitespace.",
      "Operator precedence is not a table that the parser reads. Precedence is the shape of the call chain: one function for each level, and each function calls the next tighter level.",
      "A tree-walking interpreter is a function that switches on the node kind and calls itself. All the other code is bookkeeping about names.",
      "A compiler and an interpreter differ in when the walk occurs, not in what the walk computes. The same tree gives the same answer in the two cases.",
    ],
  },
  "getting-started": {
    seoTitle: "Getting Started with Zig",
    description:
      "Install a Zig master build, compile and run your first program, run tests, " +
      "and learn what changed since the last tagged release.",
    lede:
      "Install a master build, compile Hello World, and run your first test. " +
      "If you used 0.13 or 0.14 before, the last chapter lists what moved and " +
      "shows each replacement.",
    takeaways: [
      "This guide follows Zig master, not a tagged release. The footer names the compiler that compiled every snippet on the site.",
      "A test needs no framework and no separate file. A `test` block in any compiled file is a test, and `zig test` runs it.",
      "Code from a 0.13 or 0.14 tutorial probably does not compile today. The failure is not your mistake. The last chapter tells you what moved.",
    ],
  },
  "language-basics": {
    seoTitle: "The Zig Language, by Example",
    description:
      "Runnable Zig language chapters: integers, floats, pointers, slices, " +
      "optionals, error unions, structs, unions, enums, switch, loops, comptime " +
      "and vectors.",
    lede:
      "This section teaches the language itself, with one runnable page for " +
      "each idea. The first topics are integer and float rules, pointers and " +
      "slices, optionals and error unions, and structs, unions and enums. The " +
      "other topics are switch, the loop forms, comptime and SIMD vectors. " +
      "Each page states the rule. Then the page proves the rule with a program " +
      "that you can edit in place.",
    takeaways: [
      "There is no null. An optional `?T` is a separate type. The compiler does not let you read an optional before you unwrap it.",
      "Errors are values in the return type, not exceptions. `try` is a short form that returns the error to the caller.",
      "In Debug and ReleaseSafe, integer overflow stops the program. It does not wrap. If you want wraparound arithmetic, use `+%`.",
      "`comptime` is not a macro language. `comptime` is the same Zig, run at an earlier time. Thus a generic container is a function that returns a type.",
    ],
  },
  "standard-library": {
    seoTitle: "The Zig Standard Library, by Example",
    description:
      "Zig std by example: allocators, ArrayList, hash maps, JSON, the Io " +
      "interface, readers and writers, crypto, formatting and sort.",
    lede:
      "This section shows what std contains, with a working program for each " +
      "part. The first parts are allocators and how to find a leak, ArrayList " +
      "and the hash maps, and JSON in both directions. The section also shows " +
      "the Io interface with its readers and writers, crypto, time, Unicode " +
      "and the filesystem. std changes faster than the language. When you get " +
      "a new compiler, read these pages again first.",
    takeaways: [
      "Allocation is always visible. A function that needs memory takes an `Allocator`, so you can always see which functions allocate.",
      "Blocking is also always visible. A function that can block takes an `std.Io`, and the caller decides if the `Io` uses threads.",
      "`std.testing.allocator` fails a test that leaks memory. Thus a leak fails the build here, and a user does not find it later in production.",
      "std changes faster than the language. When code does not compile after an upgrade, look here first.",
    ],
  },
  files: {
    seoTitle: "Zig File I/O: Text, Binary, Random Access and CSV",
    description:
      "How to read and write files in Zig with std.Io: full files and lines, " +
      "text and binary formats, seek and positional reads, CSV, directories and errors.",
    lede:
      "Every program in this section runs in your browser. The playground " +
      "starts each run in an empty directory. In your browser the directory is " +
      "in memory, and in CI the directory is on disk. The two runs must give " +
      "the same expected output. Thus each program writes a file before it " +
      "reads the file.",
    takeaways: [
      "`readFileAlloc` fails when the file size reaches the limit, not only when the size is more than the limit. A limit of 18 rejects an 18-byte file.",
      "A missing `flush()` loses data without an error. `close` does not know about the buffer of the writer.",
      "There is no append flag. To append, open the file and move the writer to the length of the file with `seekTo`.",
      "The filesystem decides the order of a directory listing. Sort the listing before output or a test depends on the order.",
      "If you join CSV fields with commas, you lose data without an error. A comma inside a field becomes an extra column.",
    ],
  },
  "data-structures": {
    seoTitle: "Zig Data Structures from Scratch",
    description:
      "Build containers in Zig: a growable array, a linked list, generic " +
      "containers, the intrusive lists in std, a binary search tree, AVL and a hash map.",
    lede:
      "The standard library gives you an ArrayList and a hash map, and these " +
      "chapters build them. The growable array is first, because each later " +
      "container uses one, and the array is only a length, a capacity and a " +
      "doubling rule. Next is a linked list, the smallest structure that makes " +
      "you decide who allocates and who frees. A comptime type function then " +
      "makes the list generic, and that function is all that Zig generics are. " +
      "Then come the intrusive lists that std ships today, which are very " +
      "different from the lists in older tutorials. The last chapters show a " +
      "binary search tree, the sorted input that unbalances it and the " +
      "rotations that fix it. Then a hash map shows how a delete without a " +
      "tombstone loses keys and reports no error.",
    takeaways: [
      "When the buffer doubles on each growth, append is amortised O(1). If the buffer grows by a fixed number of slots, n appends cost O(n^2).",
      "Each container decides once who allocates and who frees. That decision then appears in every signature of the container.",
      "A generic container is a comptime function that takes a type and returns a type. `ArrayList(u8)` is a call.",
      "The lists that std ships today are intrusive: the node is inside your struct. Tutorials from a year ago show a different API.",
      "If a hash map deletes a key and leaves no tombstone, the map loses every key that probed past the hole.",
    ],
  },
  concurrency: {
    seoTitle: "Zig Concurrency: std.Io, async, Cancellation and Threads",
    description:
      "Concurrency in Zig with std.Io: async, Future, Group, cancellation, " +
      "Select, queues, locks, atomics, OS threads, std.Thread today, and a batch runner.",
    lede:
      "Concurrency in Zig uses one interface. Anything that can block takes an " +
      "`std.Io`, so the function that starts the work never decides how the " +
      "work is scheduled. Only `main` makes that choice. These chapters follow " +
      "the interface from the first `io.async` call to the point where you " +
      "choose an implementation. The first topics are futures and groups, how " +
      "to stop a task that already runs, how to wait for the first task that " +
      "finishes, and a bounded queue between two tasks. The other topics are " +
      "the locks under shared state, the atomics that make those locks, and " +
      "the OS threads to use when the interface is not what you want. The " +
      "section ends with a full program, not a primitive. Five of the ten " +
      "chapters run in your browser, on a target with no threads, and this " +
      "shows that the interface keeps its promise. Read the Io Interface " +
      "chapter, in the Standard Library section, first.",
    takeaways: [
      "`std.Thread.spawn` still exists, but it is not the default now. Structured concurrency uses `std.Io`, and it compiles for targets that have no threads.",
      "`io.async` can run your function inline and return a `Future` that is already complete. Only `io.concurrent` promises that the caller continues, and `io.concurrent` can fail with `error.ConcurrencyUnavailable`.",
      "Cancellation is a request, not a kill. The task gets the request at its next cancellation point. That is the reason why anything that can block takes the `Io`.",
      "Only `main` chooses the implementation. Every function below `main` takes the interface, and never learns if the implementation has threads.",
      "A mutex is not a primitive. `std.atomic.Mutex` is one compare-and-swap that takes the lock and one ordered store that releases the lock. The type does nothing more.",
      "`std.Thread.Mutex`, `RwLock`, `Semaphore`, `Condition`, `ResetEvent`, `WaitGroup` and `Pool` do not exist now. Everything that waits moved to `std.Io`. `std.Thread` kept `spawn` and the four calls that are really about an OS thread.",
      "If the output of a concurrent program depends on the order of its tasks, nobody can test the program. Make the result independent of the schedule. Then you can change the concurrency later, and the result stays the same.",
    ],
  },
  os: {
    seoTitle: "Zig and the Operating System: Descriptors, Processes, Signals",
    description:
      "How Zig uses the operating system: file descriptors, the standard " +
      "streams, the environment, child processes, pipes, signals, and exit and defer.",
    lede:
      "Every program has this interface, if the program asked for it or not. " +
      "The program gets three descriptors that it did not open, and an " +
      "environment that it inherited. The program must return a status code " +
      "to its parent. Four of these chapters run in your browser. WASI kept " +
      "the descriptor numbers, but in the browser there is no operating system " +
      "under WASI.",
    takeaways: [
      "A file descriptor is only an integer. If you make a `File` by hand from the number 1, that `File` writes to standard output in the same way as the `File` from `stdout()`.",
      "The buffer belongs to your writer, not to the descriptor. Two writers on the same descriptor can send their bytes in a different order from the order that you wrote them.",
      "`std.posix.pipe` does not exist now. To hold one end of a pipe portably, spawn a process on the other end. To end the communication, close your end.",
      "A signal handler runs between two arbitrary instructions of your program. Set an atomic flag and return. If the handler allocates or takes a lock, the handler can deadlock the program that held that lock.",
      "`std.process.exit` runs no `defer` and empties no buffer. When you call `std.process.exit`, the bytes that are still in a writer are lost.",
    ],
  },
  networking: {
    seoTitle: "Network Programming in Zig",
    description:
      "Network programming in Zig, from sockets to protocols: framing, short " +
      "reads, text and binary protocols, byte order, many clients, TCP, UDP and HTTP.",
    lede:
      "The chapters start with sockets. Then the chapters teach the part that " +
      "decides if a server works. A stream has no message boundaries, so you " +
      "must restore the boundaries yourself. The topics are three types of " +
      "framing, a parser for a message split across two reads, text and binary " +
      "protocols in both directions, and byte order. The last topic is one " +
      "handler for each connection through the Io interface. The protocol " +
      "chapters run in your browser, because no protocol chapter uses a socket.",
    takeaways: [
      "TCP is a byte stream, not a message stream. If a read returns 7 bytes, that tells you nothing about where a message ends. Code that assumes a different result works until it runs on a real network.",
      "Parse from a `Reader`, never from a socket. Then the same parser works with a connection, with a test fixture and in a browser, and you write the parser once.",
      "State the byte order at every call. Never send a struct. You do not define the padding, and the layout is what your compiler chose today.",
      "`takeDelimiterExclusive` treats end of stream as a delimiter. If a client stops in the middle of a message, you get a fragment that looks like a complete message.",
      "`io.async` and `Group` replaced the removed `async`/`await` keywords. The same source can serve connections on a thread pool or inline, and the caller chooses.",
    ],
  },
  "build-system": {
    seoTitle: "The Zig Build System",
    description:
      "build.zig by example: build modes, cross-compilation, dependencies in " +
      "build.zig.zon, and documentation from doc comments.",
    lede:
      "build.zig is a Zig program, not a config file. These chapters show the " +
      "four build modes and the trade-off of each mode. They also show how to " +
      "cross-compile to any target with no toolchain to install, how to fetch " +
      "dependencies through build.zig.zon, and how to make docs from doc " +
      "comments.",
    takeaways: [
      "build.zig is a Zig program. If you want a conditional or a loop in your build, write one.",
      "A cross-compile installs nothing. The target is an argument, and the same command makes a binary for a machine that you do not own.",
      "The four build modes are a real choice. ReleaseSafe keeps the overflow and bounds checks. Those checks catch the bugs that this guide shows you many times.",
    ],
  },
  "working-with-c": {
    seoTitle: "Zig and C: Interop by Example",
    description:
      "How to call C from Zig and expose Zig to C: translate-c, C " +
      "pointer types, C primitive types, and the C ABI.",
    lede:
      "Zig reads C headers directly. Thus, for interop, you must know which " +
      "types cross the boundary and how they cross it. These chapters show " +
      "translate-c and what replaced @cImport, and the C pointer types and " +
      "what they refuse to do. They also show the primitive type mapping, and " +
      "how to export a C ABI that other languages can link against.",
    takeaways: [
      "Zig reads the C header itself. There is no binding file to generate, commit, and then forget to regenerate.",
      "`[*c]T` exists so that translate-c has a type to emit. At the boundary, change `[*c]T` to a real pointer or a slice. Do not let `[*c]T` spread.",
      "A plain `struct` has no guaranteed layout, and Zig can reorder its fields. A struct that crosses to C needs `extern struct` or `packed struct`.",
    ],
  },
  "how-to": {
    seoTitle: "Zig Cookbook: Runnable Recipes",
    description:
      "A Zig cookbook of runnable recipes: JSON, SQLite, the PostgreSQL wire " +
      "protocol, Redis RESP, threads and atomics, SIMD, compression and binary " +
      "formats.",
    lede:
      "Each recipe does one task, and the recipes are not a tour of the " +
      "language. The database recipes are SQLite through its C API, the " +
      "PostgreSQL wire protocol byte by byte, and a Redis RESP round trip. The " +
      "concurrency recipes use threads, atomics and a producer/consumer queue. " +
      "Other recipes show SIMD scans and dot products, zlib compression, binary " +
      "wire formats and memory layout. CI compiled and ran each recipe as a " +
      "complete program. Sockets have their own section, Networking, and are " +
      "not a recipe.",
    takeaways: [
      "Every recipe is a full program, not a fragment. If you copy the program from the page, it builds.",
      "If a recipe cannot run in your browser, the recipe tells you why: sockets, threads, a C library, or a real filesystem.",
      "Wire protocols are smaller than their client libraries suggest. PostgreSQL and RESP are each one file here, and both use the Networking chapters as a base.",
    ],
  },
  graphics: {
    seoTitle: "Zig Graphics: Software Rendering and Image Processing",
    description:
      "Software rendering and image processing in Zig, with no graphics library: " +
      "framebuffers, PNG, rasterization, blending, antialiasing, filters and scaling.",
    lede:
      "This section builds a renderer from an array of bytes, with no graphics " +
      "library under it. Start with a framebuffer and save the framebuffer as a " +
      "PNG. The next chapters draw lines and circles, rasterize triangles with " +
      "barycentric coordinates, composite with alpha, and mix colours in linear " +
      "light. Then supersampling makes jagged edges smooth. After that, the " +
      "chapters process the buffer as an image. Brightness and contrast are " +
      "lookup tables, and blur and Sobel edges are convolution kernels. " +
      "Grayscale and sepia are colour matrices, auto-levels come from a " +
      "histogram, and median filters remove noise. A chapter also shows the " +
      "half-pixel bug that shifts a resized image. The last chapters put the " +
      "buffer in a canvas to draw into part of it, map a texture across a " +
      "triangle, and move a shape with an affine matrix. Everything before the " +
      "last chapter runs in your browser.",
    note:
      "Each program in this section is the smallest program that makes one " +
      "idea visible. The programs fix their own buffer sizes. They do not have " +
      "the error handling and the fast paths that a real renderer needs. They " +
      "print ASCII so that you can check the result by eye. Where colour is " +
      "important, the programs also paint the picture, and CI checks the " +
      "pixels by their hash. Read the programs for the arithmetic and the " +
      "reasons behind it, not as code to copy into a project.",
    takeaways: [
      "A framebuffer is an array of bytes. Every chapter here is arithmetic on that array, with no library under it.",
      "Rasterization decides which pixels a shape covers. Antialiasing decides how much of each pixel the shape covers, and that is why antialiasing costs more.",
      "Blur, sharpen and edge detection are one operation with different numbers in the kernel.",
      "Resampling shifts the image by half a pixel unless you sample pixel centres. The shift looks like a rounding bug, but it is not a rounding bug.",
    ],
  },
  webassembly: {
    seoTitle: "Zig and WebAssembly",
    description:
      "How to compile Zig to WebAssembly: freestanding modules, calls from " +
      "JavaScript, data across the boundary, wasm in the browser, and a WASI command.",
    lede:
      "Zig treats wasm as an ordinary target. Thus Zig is one of the shortest " +
      "paths from compiled code to a browser. These chapters show what a " +
      "freestanding module is, and how to export functions to JavaScript. They " +
      "show how to move strings and structs across a boundary that only passes " +
      "numbers. They also show how to instantiate the module on a page, and how " +
      "to build a WASI command. This site runs on the result.",
    takeaways: [
      "wasm is an ordinary target. Nothing about the language changes, and the same source builds for your machine and for a browser.",
      "The boundary only passes numbers. A string crosses as a pointer and a length into linear memory, and both sides must agree who owns the string.",
      "Freestanding means no libc, no WASI, and no allocator except one that you supply.",
    ],
  },
  orm: {
    seoTitle: "Building an ORM in Zig",
    description:
      "An Ecto-style ORM in Zig: schemas as types, a typed query builder, " +
      "migrations as data, errdefer transactions, and an adapter seam for " +
      "SQLite and Postgres.",
    lede:
      "This project is longer than a recipe: one library, designed in public, " +
      "with one decision in each chapter. The library is a database layer in " +
      "the shape of Ecto. That design is a good stress test of comptime. The " +
      "schema is a type, and the compiler checks the query builder against " +
      "that type before the program runs. Migrations are data. The driver is " +
      "behind one seam, so the same code runs on SQLite or PostgreSQL.",
    takeaways: [
      "The schema is a type. At compile time, the library derives every other part from the schema, and declares nothing twice.",
      "A query builder that checks field names during compilation changes a class of runtime SQL errors into build errors.",
      "`errdefer` makes a transaction correct on the error paths that you did not think about.",
      "If you put the driver behind one seam, the same query code runs on two databases. If the driver code is in many places, the code runs only on the database that you wrote first.",
    ],
  },
  "url-shortener": {
    seoTitle: "Build a URL Shortener in Zig, down to the Postgres Wire Protocol",
    description:
      "A CRUD web service in Zig with no framework and no database driver: the " +
      "PostgreSQL wire protocol, base62 slugs, and HTTP handlers on plain bytes.",
    lede:
      "This project builds a working URL shortener in the same way as the rest " +
      "of this guide. It uses no framework, no driver, and no dependency that " +
      "hides how the code works. The project writes its own Postgres client, " +
      "with the wire protocol from the cookbook recipe. The slug logic and the " +
      "HTTP routes are pure functions over bytes, so most of these chapters run " +
      "in your browser. The last chapter assembles the parts into one file that " +
      "you run against a real database on your machine.",
    takeaways: [
      "A database driver is a client library that you can write. The driver connects, authenticates, sends SQL and reads rows, all as messages over one socket.",
      "When a query fails, you do not lose the connection. Postgres reports the error and then returns to ready. A client that reads the two messages can continue.",
      "A short link is base62 arithmetic on the row id, not a random string that you must check for collisions.",
      "Handlers that take request bytes and return response bytes need no server for a test. The same store seam that made the ORM testable also works for a web service.",
    ],
    note:
      "This project is a build for instruction, for a demonstration on your " +
      "own machine. Do not deploy it as a public service. It quotes values " +
      "into SQL, and does not use protocol parameters. It sends cleartext auth " +
      "on loopback, serves one request at a time, and issues slugs that are " +
      "easy to guess. Each chapter names its shortcut at the point where it " +
      "takes it.",
  },
  "lane-dodger": {
    seoTitle: "Build a Game in Zig with raylib: a Playable Endless Runner",
    description:
      "A hyper casual game in Zig and raylib that you play in the page: vendored " +
      "C, a fixed timestep, handles, a derived difficulty curve and synthesised sound.",
    lede:
      "This project builds a three lane endless runner in the same way as the " +
      "rest of this guide: no engine, no assets, and nothing that hides how it " +
      "works. The game is on this page, and you can play it now. The chapters " +
      "teach how to write a game that you can test. The usual answer is that " +
      "you cannot test a game, and the usual result is a game whose difficulty " +
      "nobody can reason about. Here the simulation imports nothing, so a " +
      "program that plays the game checks every rule, and the graphics and the " +
      "sound come later, on top of the simulation.",
    takeaways: [
      "If a game loop takes a `dt`, the game plays differently on each machine. A fixed timestep with an accumulator is ten lines, and it gives reproducible runs.",
      "If game logic imports no graphics library, a program can test the logic when it plays the game. Here, a bot tests the rules at every seed in about one second, with no window open.",
      "Derive a difficulty curve from what is physically possible. Do not tune the curve until it feels correct. When one tuned number changes, the tuned numbers no longer agree with each other.",
      "For objects that a program spawns and destroys constantly, handles work better than pointers. A stale index silently reads the next occupant of its slot. A generation counter changes that read into a null.",
      "Sound effects can be a few hundred lines of arithmetic, not a folder of files. Waveforms are as easy to test as other code.",
    ],
    note:
      "This project vendors raylib from its C sources at a pinned commit, and " +
      "does not use raylib as a Zig package. The chapters explain why. The " +
      "browser build needs the Emscripten SDK, and CI does not have that SDK. " +
      "Thus the playable artefacts on this page are built by hand and committed.",
  },
  paint: {
    seoTitle: "Build a Paint Program in Zig: Brushes, Layers, Undo and PNG",
    description:
      "A paint program in Zig that runs in the page, with no graphics library: " +
      "brushes, a 16-bit stroke buffer, layers, undo, flood fill and PNG export.",
    lede:
      "This project is a paint program that you can use on this page. The " +
      "engine under it never sees a mouse. The engine takes points and gives " +
      "pixels, so tests that draw with no window check every brush, every " +
      "layer and every undo. The browser build is about 150 KB of WebAssembly. " +
      "Before the site ships the build, the build must draw a test picture with " +
      "exactly the pixels that the native tests pinned.",
    takeaways: [
      "If you make one mark for each pointer event, the stroke depends on hand speed. Walk the path, and carry the distance that is left into the next segment. Then the spacing stays even.",
      "A stroke at 50% opacity must stay at 50% where it crosses itself. Build the coverage of the stroke in a separate buffer. Apply the opacity once, at the end.",
      "Undo does not need a copy of the picture. Keep the rectangle that an action changed. Then undo and redo become the same swap.",
      "When no memory is available, the program should lose an undo step, not the stroke. In Zig, that failure is an ordinary error, and you decide what to do with it.",
    ],
    note:
      "The engine is plain Zig, built for wasm32-freestanding. Thus CI builds " +
      "the file that this page runs, and nothing is committed. The engine is a " +
      "program for instruction: one brush engine, two layers, and 8-bit colour " +
      "that blends in the same way as a browser canvas.",
  },
  "competitive-programming": {
    seoTitle: "Zig for Competitive Programming: Algorithms That Print Their Working",
    description:
      "Contest algorithms in Zig, one complete program per chapter. Each program " +
      "prints its steps, from binary search and two pointers to knapsack.",
    lede:
      "A contest problem reads its input from stdin. A snippet here runs under " +
      "WASI in a browser tab, and the tab has no stdin. Thus each chapter puts " +
      "its input in the source as text, and parses the text in the same way as " +
      "a file. The last chapter, the contest template, reads real stdin, and " +
      "it takes the same reader. The algorithm does not change, and in " +
      "exchange every program prints the steps that it took. The trace in the " +
      "chapter is the trace that CI diffed against the compiler that the " +
      "footer names.",
    takeaways: [
      "Binary search is a window that gets smaller, not a clever midpoint. Every index that can be the answer stays inside `items[lo..hi]`. The loop ends when no index is left to examine.",
      "The classic off-by-one does not return a wrong index. The search never returns, because a window of one has a middle equal to its own start.",
      "`(lo + hi) / 2` adds two valid indices, but their sum is not always valid. `lo + (hi - lo) / 2` costs nothing and cannot overflow.",
      "Two bounds give more information than one search. The start and the end of a value give a count, and you need no scan to get the count.",
      "When two pointers converge on sorted data, they never have a choice about the next move. One index leaves the range at each step, so a walk that looks like a search costs one pass.",
      "A sliding window adds the value that enters and subtracts the value that leaves. Every index enters once and leaves once, so a loop inside a loop is still linear. The shrink rule fails when a value can be negative.",
      "`std.sort.lowerBound` passes the key first and the element second. If you write a comparator in the opposite order, it compiles and returns a wrong index that looks correct.",
    ],
    clues: [
      { says: "The array is sorted. Find a value, or where it would go.", chapters: ["competitive-programming/binary-search"] },
      { says: "The answer is a number, and \"can it be done with x?\" changes from no to yes exactly once.", chapters: ["competitive-programming/binary-search-answer"] },
      { says: "The array is sorted. Find a pair that adds up to a target.", chapters: ["competitive-programming/two-pointers"] },
      { says: "Best sum over every contiguous run of length k.", chapters: ["competitive-programming/sliding-window"] },
      { says: "Shortest contiguous run that reaches a target, and no value is negative.", chapters: ["competitive-programming/sliding-window"] },
      { says: "Sum of a range, asked many times.", chapters: ["competitive-programming/prefix-sums"] },
      { says: "Add to a range, many times, then read every value once.", chapters: ["competitive-programming/prefix-sums"] },
      { says: "For every position, the next value that is larger or smaller.", chapters: ["competitive-programming/monotonic-stack"] },
      { says: "The largest or smallest value in every window.", chapters: ["competitive-programming/monotonic-deque"] },
      { says: "Fewest steps across a grid, where every step costs the same.", chapters: ["competitive-programming/grid-bfs"] },
      { says: "Ranges that overlap. Merge them, or measure what they cover.", chapters: ["competitive-programming/merge-intervals"] },
      { says: "Connections arrive one at a time. Are these two linked yet?", chapters: ["competitive-programming/union-find"] },
      { says: "Choose items under a limit, each one at most once.", chapters: ["competitive-programming/knapsack"] },
      { says: "Always take the smallest or largest item that is left.", chapters: ["standard-library/priority-queue"] },
      { says: "Did this value occur before, and how many times?", chapters: ["standard-library/hash-maps"] },
      { says: "Brackets that must match, or steps that must be undone in reverse.", chapters: ["standard-library/stacks"] },
    ],
  },
};

/** Copy for a group index (a body of work that lives one directory deeper). */
export const GROUPS: Record<string, SectionMeta> = {
  "how-to/databases": {
    seoTitle: "Zig Database Recipes",
    description:
      "How to talk to a database from Zig: SQLite through its C API, the " +
      "PostgreSQL wire protocol byte by byte, and a Redis RESP round trip.",
    lede:
      "These recipes show three ways to use a database from Zig, at three " +
      "different levels, and the first is SQLite through its C API. SQLite is the " +
      "shortest path to durable storage, and a clear example of how Zig links " +
      "C. The second is the PostgreSQL wire protocol, written by hand from the " +
      "startup message to the row description. The protocol is simpler " +
      "than its client libraries suggest. The third is Redis RESP, which is " +
      "small enough to parse in one page. For a query layer on top of these " +
      "recipes, see the ORM chapters in Projects.",
    takeaways: [
      "A database driver is mostly a codec. When the framing code is complete, a query is one message that you send. Then you read a stream of messages until the server says that it is ready again.",
      "Postgres and Redis both frame every message with a type and a length. It is simpler to implement either protocol than to install a client library for it. The complexity in a real driver is pooling, auth and types, not the protocol.",
      "If protocol code reads from a `Reader` and not from a socket, you can test the code with a string literal.",
      "SQLite is a C library. Thus the SQLite recipe is also the shortest realistic example of translate-c, of linking, and of how to change C error codes into Zig errors.",
    ],
  },
};
