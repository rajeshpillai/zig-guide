/**
 * Everything a search engine or a link preview reads about this site, in one
 * place. `Base.astro`, the sitemap, `robots.txt` and the section index pages
 * all read from here, so a title and the canonical URL that advertises it can
 * never drift apart.
 */

export const SITE_NAME = "Zig Guide Live";

export const SITE_DESCRIPTION =
  "A Zig tutorial and cookbook where every snippet is compiled and run against " +
  "current Zig master on every build, and runs in your browser as WebAssembly.";

export const AUTHOR = "Rajesh Pillai";

/**
 * The one address a reader can write to. Plain text in a `mailto:`, not
 * assembled by a script: this is the only direct route to a person on a site
 * with no server to receive a form, so it has to work with JS off and has to
 * be readable by anything that fetches the page rather than renders it.
 */
export const AUTHOR_EMAIL = "pillai.rajesh@gmail.com";

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
}

export const SECTIONS: Record<string, SectionMeta> = {
  "systems-from-scratch": {
    seoTitle: "Systems Programming from Scratch, in Zig",
    description:
      "Learn what a systems programmer knows, starting from nothing: bytes and " +
      "types, integer sizes and overflow, addresses, the stack, who owns memory, " +
      "bounds and build modes, strings as bytes, struct layout and padding, " +
      "errors as values, and the system call boundary. Every idea has one " +
      "complete program you can run in the page.",
    lede:
      "Systems programming taught from zero, with Zig as the vehicle instead of " +
      "C. Each chapter asks one question, answers it in plain terms, and then " +
      "hands you a complete program that proves the answer. If you have written " +
      "C before, the last part of each page says how the same idea is spelled " +
      "there. If you have not, nothing here needs it. The order is the one a C " +
      "course takes. Nothing earlier in the guide is a prerequisite, so read it " +
      "whenever the machine underneath starts mattering, including first.",
    takeaways: [
      "A type is not a property of the bytes. It is an agreement about how to read them, and the same four bytes can be read two ways without converting anything.",
      "`u8` and `u32` are not styles of writing a number. They are different amounts of memory, and the difference is a million bytes when you have a million of them.",
      "An address is an ordinary number. `@intFromPtr` does no work; it shows you the number the pointer was already holding.",
      "A call's locals are handed back when it returns, and the next call gets the same bytes. That reuse is the dangling pointer, and nothing about the pointer changed.",
      "Undefined behaviour is not a crash and not a garbage value. It is a promise you made to the compiler, which is why breaking it can change code somewhere else.",
    ],
  },
  terminal: {
    seoTitle: "Survive the Terminal: String and Shell Primitives in Zig",
    description:
      "Build the primitives a shell needs before it can exist: string length, " +
      "comparison, copying and trimming written out by hand, a command-line " +
      "tokenizer, and the read-eval-print loop itself.",
    lede:
      "Before a shell can run a command it has to measure a string, compare " +
      "one, copy one without running off the end, split a line into arguments, " +
      "and loop until the user or the input stops. Three chapters, each one " +
      "primitive built rather than imported. The parts that need a real kernel, " +
      "fork, exec and pipes, are in the operating system section already.",
    takeaways: [
      "`strlen` is a walk, every time you call it. That cost is the whole argument for a slice that already knows its length.",
      "A buffer for a 5-byte string needs 6 bytes. The version of the bounds check that forgets the terminator passes a casual test and writes one byte past the end.",
      "Trimming returns a view, not a copy. Moving bytes to remove spaces is work you never needed to do.",
      "A REPL has two exits, not one. A loop that only watches for `quit` spins forever the first time someone presses Ctrl-D.",
    ],
  },
  "unix-tools": {
    seoTitle: "Build the Unix Tools in Zig: cat, wc, grep, sort, cut, printf, make",
    description:
      "Rebuild the standard Unix toolbox in Zig, one complete program per " +
      "chapter: cat, wc, grep, sort, cut, printf and make. Each one runs in " +
      "the page, and each explains the technique it exists to teach.",
    lede:
      "Seven tools you use every day, rebuilt from nothing. Each chapter is one " +
      "complete program and one technique: streaming reads, a state machine, " +
      "searching, owning the lines you sorted, splitting on a delimiter, turning " +
      "a number into text, and deciding what needs rebuilding. The tools are " +
      "small enough to hold in your head and old enough that their design is " +
      "the lesson.",
    takeaways: [
      "`cat` is a loop around a fixed buffer. The buffer size is a decision about memory, not about correctness, which is why it can copy a file larger than memory.",
      "`wc` counts words by counting transitions into a word, not words. That is a state machine, and it is why leading spaces and double spaces cost nothing.",
      "Sorting lines means owning them. The moment the sorted output has to outlive the buffer it was read into, you have to answer who allocates.",
      "`printf` builds its digits backwards, because the only way to get the last digit of a number is to divide, and division hands them to you in reverse.",
      "`make` is a topological sort over a graph of file timestamps. Everything else about it is syntax.",
    ],
  },
  "web-server": {
    seoTitle: "Build an HTTP Server in Zig, from the Bytes Up",
    description:
      "Parse an HTTP request by hand, format a response, and serve it over a " +
      "real socket. The protocol is text, the framing is a blank line, and " +
      "none of it needs a framework.",
    lede:
      "HTTP is a text protocol simple enough to implement in an afternoon and " +
      "strict enough that the details matter. These chapters parse a request " +
      "into a method, a target and headers, then put a socket in front of the " +
      "parser and answer a real client. The parsing runs in this page; the " +
      "server binds a port, so it runs on the build machine instead, and CI " +
      "checks what the client received.",
    takeaways: [
      "HTTP declares no length up front, so a server reads until it sees a blank line. That single rule is the whole framing problem.",
      "Header names are case-insensitive. Comparing them exactly works against your own client and fails against somebody else's proxy.",
      "A response without Content-Length leaves the client waiting, because nothing else tells it the body ended.",
      "The parser never needs a socket. Taking bytes and returning a request is what lets the same code be tested, fuzzed, and run on a page with no network at all.",
    ],
  },
  storage: {
    seoTitle: "Build a Database in Zig: Logs, Locks and Indexes",
    description:
      "How storage engines actually work: an append-only record log, the lost " +
      "update two writers cause, indexes that turn a scan into a lookup, and a " +
      "write-ahead log that survives a crash.",
    lede:
      "Every database is a file, plus the rules that keep it honest when two " +
      "things touch it at once and when the power goes out. These chapters " +
      "build those rules from nothing: append-only records, a lock, an index, " +
      "and a log written before the change it describes.",
    takeaways: [
      "An append-only file cannot delete. Removal is a record you add, which is why every log-structured store has tombstones.",
      "Read, modify, write is three steps, and the gap between the first and the third is where the other writer gets in.",
      "A race gives a different answer every run. That is what makes it expensive to find, not what makes it rare.",
      "An index does not make the data smaller. It adds a second structure you now have to keep in step with the first.",
    ],
  },
  browser: {
    seoTitle: "Build a Browser in Zig: Parse HTML, Match CSS, Lay Out, Render",
    description:
      "The pipeline behind every page: an HTML parser that cannot fail, a CSS " +
      "parser and selector matcher, a layout engine that turns a tree into " +
      "boxes, and a renderer that turns boxes into pixels.",
    lede:
      "A browser is four programs in a row, and each one is understandable on " +
      "its own. Bytes become a tree, a stylesheet decides what each node looks " +
      "like, the tree becomes rectangles with positions, and the rectangles " +
      "become pixels. The scripting engine at the end is the language built " +
      "earlier in this track, pointed at a document.",
    takeaways: [
      "HTML has no parse errors by design. Every malformed document has a defined tree, because the browsers that shipped first had to render the web that already existed.",
      "A void element is complete on its own. Treating `<br>` as an unclosed tag swallows the rest of the page.",
      "Layout is two passes, not one: widths flow down from the parent, heights add up from the children.",
      "The cascade is a sort. Specificity, then order, and the last rule standing wins.",
    ],
  },
  "tiny-lang": {
    seoTitle: "Write a Programming Language in Zig",
    description:
      "Build a small language from nothing: a lexer, a recursive descent " +
      "parser, a tree-walking interpreter, call frames, a bytecode compiler " +
      "and the virtual machine that runs it. Every stage runs in the page.",
    lede:
      "A language with variables, arithmetic, conditionals and loops, built one " +
      "stage at a time. Each chapter takes the output of the last: characters " +
      "become tokens, tokens become a tree, the tree is walked, and then the " +
      "same tree is compiled to bytecode for a stack machine. None of it needs " +
      "a kernel, so all of it runs here.",
    takeaways: [
      "A lexer is one pass with one character of lookahead. Whitespace disappears there, which is why no later stage has to think about it.",
      "Operator precedence is not a table the parser consults. It is the shape of the call chain: one function per level, each calling the tighter one.",
      "A tree-walking interpreter is a switch on the node kind that calls itself. That is the entire idea, and everything else is bookkeeping about names.",
      "Compiling and interpreting differ in when the walk happens, not in what it computes. The same tree produces the same answer either way.",
    ],
  },
  "getting-started": {
    seoTitle: "Getting Started with Zig",
    description:
      "Install a Zig master build, compile and run your first program, run tests, " +
      "and catch up on what changed since the last tagged release.",
    lede:
      "Install a master build, compile Hello World, and run your first test. " +
      "If you are arriving from 0.13 or 0.14, the last chapter lists what moved " +
      "and what the replacement looks like.",
    takeaways: [
      "This guide follows Zig master, not a tagged release. The compiler named in the footer is the one that compiled every snippet on the site.",
      "A test needs no framework and no separate file. A `test` block in any compiled file is a test, and `zig test` runs it.",
      "Code from a 0.13 or 0.14 tutorial probably does not compile today. That is not your mistake, and the last chapter says what moved.",
    ],
  },
  "language-basics": {
    seoTitle: "The Zig Language, by Example",
    description:
      "Zig language chapters you can run: integers, floats, pointers, slices, " +
      "optionals, error unions, structs, unions, enums, switch, loops, comptime " +
      "and vectors.",
    lede:
      "The language itself, one runnable page per idea: integer and float rules, " +
      "pointers and slices, optionals and error unions, structs, unions and enums, " +
      "switch, the loop forms, comptime, and SIMD vectors. Each page states the " +
      "rule and then proves it with a program you can edit in place.",
    takeaways: [
      "There is no null. An optional `?T` is its own type, and the compiler will not let you read one without unwrapping it first.",
      "Errors are values in the return type, not exceptions. `try` is shorthand for returning one to the caller.",
      "Signed overflow is a crash in Debug and ReleaseSafe, not a wrap. If you want wrapping, ask for it with `+%`.",
      "`comptime` is not a macro language. It is the same Zig, run earlier, which is why a generic container is a function that returns a type.",
    ],
  },
  "standard-library": {
    seoTitle: "The Zig Standard Library, by Example",
    description:
      "Zig std by example: allocators, ArrayList, hash maps, JSON, the Io " +
      "interface, readers and writers, threads, crypto, formatting and sorting.",
    lede:
      "What ships in std, with a working program for each piece: allocators and " +
      "how to catch a leak, ArrayList and the hash maps, JSON in both directions, " +
      "the Io interface with its readers and writers, threads, crypto, time, " +
      "Unicode and the filesystem. std moves faster than the language, so these " +
      "are the pages most worth re-reading against a fresh compiler.",
    takeaways: [
      "Nothing allocates behind your back. A function that needs memory takes an `Allocator`, so you can always see what will.",
      "Nothing blocks behind your back either. A function that can block takes an `std.Io`, and the caller decides whether that means threads.",
      "`std.testing.allocator` fails a test that leaks. A leak is a red build here, not something found in production later.",
      "std moves faster than the language does. When something stops compiling after an upgrade, look here first.",
    ],
  },
  "data-structures": {
    seoTitle: "Zig Data Structures from Scratch",
    description:
      "Building containers in Zig: a linked list with an allocator you own, " +
      "generic containers as comptime type functions, the intrusive lists std " +
      "actually ships, a binary search tree, AVL rotations, and a hash map with " +
      "open addressing.",
    lede:
      "The standard library hands you an ArrayList and a hash map. These chapters " +
      "build them. A linked list first, because it is the smallest structure that " +
      "forces you to answer who allocates and who frees. Then the same list made " +
      "generic by a comptime type function, which is all Zig's generics are. Then " +
      "the intrusive lists std actually ships today, which look nothing like the " +
      "ones in older tutorials. Then a binary search tree, the sorted input that " +
      "ruins it, and the rotations that fix it. Finally a hash map, where deleting " +
      "without a tombstone quietly loses your keys.",
    takeaways: [
      "Who allocates and who frees is decided once per container, and then it shows up in every signature that container has.",
      "A generic container is a comptime function that takes a type and returns a type. `ArrayList(u8)` is a call.",
      "The lists std ships today are intrusive: the node lives inside your struct. Tutorials written a year ago show a different API.",
      "A hash map that deletes without leaving a tombstone loses every key that probed past the hole.",
    ],
  },
  os: {
    seoTitle: "Zig and the Operating System: Descriptors, Processes, Signals",
    description:
      "Talking to the operating system from Zig: file descriptors, the standard " +
      "streams, the environment, spawning a child process, pipes, signal " +
      "handlers, and what exit does to your defers.",
    lede:
      "The interface every program has whether it asked for one or not: three " +
      "descriptors it did not open, an environment it inherited, and a status " +
      "code it owes its parent. Four of these chapters run in your browser, " +
      "because WASI kept the descriptor numbering even though there is no " +
      "operating system underneath.",
    takeaways: [
      "A file descriptor is an integer and nothing more. A `File` built by hand out of the number 1 writes to standard output exactly as the one `stdout()` returns does.",
      "Buffering belongs to your writer, not to the descriptor. Two writers on the same descriptor can deliver their bytes in the order you did not write them.",
      "There is no `std.posix.pipe` any more. The portable way to hold one end of a pipe is to spawn a process on the other, and the way to end the conversation is to close your end.",
      "A signal handler runs between two arbitrary instructions of whatever you were doing. Set an atomic flag and return; anything that allocates or takes a lock can deadlock the program that was holding it.",
      "`std.process.exit` runs no `defer` and drains no buffer. Bytes still in a writer when it is called are simply lost.",
    ],
  },
  networking: {
    seoTitle: "Network Programming in Zig",
    description:
      "Network programming in Zig from the socket up: message framing, short " +
      "reads, text and binary protocols, byte order, serving many clients " +
      "through std.Io, TCP, UDP and HTTP.",
    lede:
      "Sockets from the beginning, then the part that actually decides whether " +
      "a server works: a stream has no message boundaries, so you put them back " +
      "yourself. Framing three ways, a parser that survives a message split " +
      "across two reads, text and binary protocols in both directions, byte " +
      "order, and one handler per connection through the Io interface. The " +
      "protocol chapters run in your browser, because none of them know what a " +
      "socket is.",
    takeaways: [
      "TCP is a byte stream, not a message stream. A read returning 7 bytes says nothing about where a message ends, and code that assumes otherwise works until it meets a real network.",
      "Parse from a `Reader`, never from a socket. The same parser then works over a connection, over a test fixture and in a browser, and you write it once.",
      "State the byte order at every call, and never send a struct. Padding is not yours to define and the layout is whatever your compiler chose today.",
      "`takeDelimiterExclusive` treats end of stream as a delimiter, so a client that dies mid-message hands you a fragment that looks like a complete one.",
      "`io.async` and `Group` replaced the removed `async`/`await` keywords. The same source serves connections on a thread pool or inline, and the caller picks.",
    ],
  },
  "build-system": {
    seoTitle: "The Zig Build System",
    description:
      "build.zig by example: build modes, cross-compilation, declaring " +
      "dependencies in build.zig.zon, and generating documentation.",
    lede:
      "build.zig is a Zig program, not a config file. These chapters cover the " +
      "four build modes and what each trades, cross-compiling to any target " +
      "without a toolchain to install, fetching dependencies through " +
      "build.zig.zon, and generating docs from doc comments.",
    takeaways: [
      "build.zig is a Zig program. When you want a conditional or a loop in your build, you write one.",
      "Cross-compiling installs nothing. The target is an argument, and the same command produces a binary for a machine you do not own.",
      "The four build modes are a real choice. ReleaseSafe keeps the overflow and bounds checks that catch the bugs this guide keeps showing you.",
    ],
  },
  "working-with-c": {
    seoTitle: "Zig and C: Interop by Example",
    description:
      "Calling C from Zig and exposing Zig to C: @cImport and translate-c, C " +
      "pointer types, C primitive types, and the C ABI.",
    lede:
      "Zig reads C headers directly, so interop is a matter of knowing which " +
      "types cross the boundary and how. These chapters cover @cImport and " +
      "translate-c, the C pointer types and what they refuse to do, the primitive " +
      "type mapping, and exporting a C ABI other languages can link against.",
    takeaways: [
      "Zig reads the C header itself. There is no binding file to generate, commit, and then forget to regenerate.",
      "`[*c]T` exists so translate-c has something to emit. Turn it into a real pointer or a slice at the boundary and do not let it spread.",
      "A plain `struct` has no guaranteed layout and Zig may reorder its fields. Anything crossing to C needs `extern struct` or `packed struct`.",
    ],
  },
  "how-to": {
    seoTitle: "Zig Cookbook: Runnable Recipes",
    description:
      "A Zig cookbook of runnable recipes: JSON, SQLite, the PostgreSQL wire " +
      "protocol, Redis RESP, threads and atomics, SIMD, compression and binary " +
      "formats.",
    lede:
      "Task-shaped recipes rather than a tour of the language. Databases: SQLite " +
      "through its C API, the PostgreSQL wire protocol byte by byte, and a Redis " +
      "RESP round trip. Concurrency with threads, atomics and a producer/consumer " +
      "queue. SIMD scanning and dot products, zlib compression, binary wire " +
      "formats, and memory layout. Every recipe is a complete program that CI " +
      "compiled and ran. Sockets themselves are a section rather than a recipe: " +
      "see Networking.",
    takeaways: [
      "Every recipe is a whole program, not a fragment. Copy the page and it builds.",
      "A recipe that will not run in your browser says so and says why: sockets, threads, a C library, or a real filesystem.",
      "Wire protocols are smaller than their client libraries suggest. PostgreSQL and RESP are each one file here, and both build on Networking.",
    ],
  },
  graphics: {
    seoTitle: "Zig Graphics: Software Rendering and Image Processing",
    description:
      "Software rendering and image processing in Zig with no graphics library: " +
      "framebuffers, rasterizing lines, circles and triangles, alpha blending, " +
      "antialiasing, brightness and contrast, gaussian blur, Sobel edges, colour " +
      "matrices, histogram equalization, median filters, and image scaling.",
    lede:
      "A renderer built out of an array of bytes, with no graphics library " +
      "underneath. Start with a framebuffer, draw lines and circles, rasterize " +
      "triangles with barycentric coordinates, composite with alpha, and kill the " +
      "staircase with supersampling. Then read the buffer back: brightness and " +
      "contrast as lookup tables, blur and Sobel edges as convolution kernels, " +
      "grayscale and sepia as colour matrices, auto-levels from a histogram, " +
      "median filters for noise, and the half-pixel bug that shifts a resized " +
      "image. Wrap the buffer in a canvas to draw into part of it, map a texture " +
      "across a triangle, and move a shape with an affine matrix. Everything " +
      "before the last chapter runs in your browser.",
    note:
      "Every program in this section is cut down to the smallest thing that " +
      "makes one idea visible. They fix their own buffer sizes, leave out the " +
      "error handling and the fast paths a real renderer needs, and print ASCII " +
      "rather than pixels so the result can be checked by eye. Read them for the " +
      "arithmetic and the reasoning behind it, not as code to lift into a project.",
    takeaways: [
      "A framebuffer is an array of bytes. Every chapter here is arithmetic on that array, with no library underneath.",
      "Rasterizing decides which pixels a shape covers. Antialiasing decides how much of each, which is why it costs more.",
      "Blur, sharpen and edge detection are one operation with different numbers in the kernel.",
      "Resampling shifts the image half a pixel unless you sample pixel centres. It looks like a rounding bug and it is not.",
    ],
  },
  webassembly: {
    seoTitle: "Zig and WebAssembly",
    description:
      "Compiling Zig to WebAssembly: freestanding modules, calling Zig from " +
      "JavaScript, passing data across the boundary, loading wasm in the browser, " +
      "and building a WASI command.",
    lede:
      "Zig treats wasm as an ordinary target, which makes it one of the shortest " +
      "paths to shipping compiled code to a browser. These chapters cover what a " +
      "freestanding module actually is, exporting functions to JavaScript, moving " +
      "strings and structs across a boundary that only passes numbers, " +
      "instantiating the module on a page, and building a WASI command. This site " +
      "runs on the result.",
    takeaways: [
      "wasm is an ordinary target. Nothing about the language changes, and the same source builds for your machine and for a browser.",
      "The boundary only passes numbers. A string crosses as a pointer and a length into linear memory, and both sides have to agree who owns it.",
      "Freestanding means no libc, no WASI and no allocator you did not bring yourself.",
    ],
  },
  orm: {
    seoTitle: "Building an ORM in Zig",
    description:
      "An Ecto-style ORM in Zig: schemas as types, a typed query builder, " +
      "migrations as data, transactions with errdefer, and an adapter seam over " +
      "SQLite and PostgreSQL.",
    lede:
      "Longer than a recipe: one library, designed in the open, one decision per " +
      "chapter. A database layer in the shape of Ecto, which is a good stress " +
      "test of comptime because the schema is a type, the query builder is " +
      "checked against that type before the program runs, migrations are data, " +
      "and the driver sits behind one seam so the same code runs on SQLite or " +
      "PostgreSQL.",
    takeaways: [
      "The schema is a type. Every other part of the library is derived from it at compile time rather than declared twice.",
      "A query builder that checks field names during compilation turns a class of runtime SQL errors into build errors.",
      "`errdefer` is what makes a transaction correct on the error paths you did not think about, which are the ones that matter.",
      "Put the driver behind one seam and the same query code runs on two databases. Scatter it and it runs on whichever you wrote first.",
    ],
  },
  "url-shortener": {
    seoTitle: "Build a URL Shortener in Zig, down to the Postgres Wire Protocol",
    description:
      "A CRUD web service in Zig with no framework and no database driver: " +
      "the PostgreSQL wire protocol spoken directly, base62 slugs, HTTP " +
      "handlers that take bytes and return bytes, and one file that runs " +
      "against a real database.",
    lede:
      "A working URL shortener, built the way this guide builds everything: " +
      "no framework, no driver, no dependency that hides the interesting " +
      "part. The Postgres client is written here, speaking the wire protocol " +
      "from the cookbook recipe. The slug logic and the HTTP routes are pure " +
      "functions over bytes, which is why most of these chapters run in your " +
      "browser. The last chapter assembles the pieces into one file you run " +
      "against a real database on your machine.",
    takeaways: [
      "A database driver is a client library you can write: connect, authenticate, send SQL, read rows, all as messages over one socket.",
      "A failed query does not cost you the connection. Postgres reports the error and returns to ready, and a client that reads both keeps going.",
      "A short link is base62 arithmetic on the row id, not a random string you have to check for collisions.",
      "Handlers that take request bytes and return response bytes need no server to be tested, and the same store seam that made the ORM testable works on a web service.",
    ],
    note:
      "This project is a teaching build, for demonstration on your own " +
      "machine. Do not deploy it as a public service: it quotes values into " +
      "SQL instead of using protocol parameters, speaks cleartext auth on " +
      "loopback, serves one request at a time, and issues guessable slugs. " +
      "Each chapter names its shortcut where it takes it.",
  },
  "lane-dodger": {
    seoTitle: "Build a Game in Zig with raylib: a Playable Endless Runner",
    description:
      "A complete hyper casual game in Zig and raylib, playable in the page. " +
      "Vendoring raylib's C so a dependency cannot break your build, a fixed " +
      "timestep loop, an entity pool with generational handles, a difficulty " +
      "curve derived from what is possible rather than guessed at, and sound " +
      "effects synthesised in code. Fifty-five tests, none of which opens a " +
      "window.",
    lede:
      "A three lane endless runner, built the way this guide builds " +
      "everything: no engine, no assets, nothing hiding the interesting part. " +
      "The game is on this page and you can play it now. What the chapters " +
      "are actually about is how to write a game you can test, because the " +
      "usual answer is that you cannot, and the usual result is a game whose " +
      "difficulty nobody can reason about. The simulation here imports " +
      "nothing at all, so every rule is checked by a program that plays the " +
      "game, and the graphics and the sound are both things that happen to " +
      "it afterwards.",
    takeaways: [
      "A game loop that takes a `dt` is a game that plays differently on every machine. A fixed timestep with an accumulator costs ten lines and buys reproducible runs.",
      "Game logic that imports no graphics library can be tested by playing it. The rules here are exercised by a bot at every seed, in about a second, with no window open.",
      "A difficulty curve should be derived from what is physically possible, not tuned until it feels right. Tuned numbers stop agreeing with each other the first time one of them moves.",
      "Handles beat pointers for anything spawned and destroyed constantly: a stale index silently reads its slot's next occupant, and a generation counter turns that into a null.",
      "Sound effects can be a few hundred lines of arithmetic rather than a folder of files, and waveforms are as testable as anything else.",
    ],
    note:
      "raylib is vendored from its C sources at a pinned commit rather than " +
      "used as a Zig package, and the chapters explain why. The browser build " +
      "needs the Emscripten SDK, which CI does not carry, so the playable " +
      "artefacts on this page are built by hand and committed.",
  },
};

/** Copy for a group index (a body of work that lives one directory deeper). */
export const GROUPS: Record<string, SectionMeta> = {
  "how-to/databases": {
    seoTitle: "Zig Database Recipes",
    description:
      "Talking to a database from Zig: SQLite through its C API, the PostgreSQL " +
      "wire protocol implemented byte by byte over a socket, and a Redis RESP " +
      "round trip.",
    lede:
      "Three ways into a database from Zig, at three different levels. SQLite " +
      "through its C API, which is the shortest path to durable storage and a " +
      "good look at how Zig links C. The PostgreSQL wire protocol written out by " +
      "hand, startup message through row description, because the protocol is " +
      "simpler than its client libraries suggest. And Redis RESP, which is small " +
      "enough to parse in one page. For a query layer on top of these, see the " +
      "ORM chapters under Projects.",
    takeaways: [
      "A database driver is mostly a codec. Once the framing is written out, a query is a message you send and a stream of messages you read until the server says it is ready again.",
      "Postgres and Redis both frame every message with a type and a length, and both are simpler to implement than to install a client library for. The complexity in a real driver is pooling, auth and types, not the protocol.",
      "Protocol code that reads from a `Reader` rather than a socket can be tested with a string literal, which is why two of these three recipes run in your browser.",
      "SQLite is a C library, so this is also the shortest realistic example of `@cImport`, linking, and turning C error codes into Zig errors.",
    ],
  },
};
