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
      "course takes, ending where Getting Started begins.",
    takeaways: [
      "A type is not a property of the bytes. It is an agreement about how to read them, and the same four bytes can be read two ways without converting anything.",
      "`u8` and `u32` are not styles of writing a number. They are different amounts of memory, and the difference is a million bytes when you have a million of them.",
      "An address is an ordinary number. `@intFromPtr` does no work; it shows you the number the pointer was already holding.",
      "A call's locals are handed back when it returns, and the next call gets the same bytes. That reuse is the dangling pointer, and nothing about the pointer changed.",
      "Undefined behaviour is not a crash and not a garbage value. It is a promise you made to the compiler, which is why breaking it can change code somewhere else.",
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
      "image. Everything before the last chapter runs in your browser.",
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
  },
};
