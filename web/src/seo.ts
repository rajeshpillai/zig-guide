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
}

export const SECTIONS: Record<string, SectionMeta> = {
  "getting-started": {
    seoTitle: "Getting Started with Zig",
    description:
      "Install a Zig master build, compile and run your first program, run tests, " +
      "and catch up on what changed since the last tagged release.",
    lede:
      "Install a master build, compile Hello World, and run your first test. " +
      "If you are arriving from 0.13 or 0.14, the last chapter lists what moved " +
      "and what the replacement looks like.",
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
  },
  "how-to": {
    seoTitle: "Zig Cookbook: Runnable Recipes",
    description:
      "A Zig cookbook of runnable recipes: JSON, TCP, UDP and HTTP, SQLite, the " +
      "PostgreSQL wire protocol, Redis RESP, threads and atomics, SIMD, " +
      "compression and binary formats.",
    lede:
      "Task-shaped recipes rather than a tour of the language. Networking over " +
      "TCP, UDP and HTTP. Databases: SQLite through its C API, the PostgreSQL " +
      "wire protocol byte by byte, and a Redis RESP round trip. Concurrency with " +
      "threads, atomics and a producer/consumer queue. SIMD scanning and dot " +
      "products, zlib compression, binary wire formats, and memory layout. Every " +
      "recipe is a complete program that CI compiled and ran.",
  },
  graphics: {
    seoTitle: "Zig Graphics: Software Rendering and Image Processing",
    description:
      "Software rendering and image processing in Zig with no graphics library: " +
      "framebuffers, line and circle rasterization, triangles, alpha blending, " +
      "antialiasing, brightness and contrast, gaussian blur, Sobel edge " +
      "detection, colour matrices, writing a PNG, and putting pixels on a screen.",
    lede:
      "A renderer built out of an array of bytes, with no graphics library " +
      "underneath. Start with a framebuffer, draw lines and circles, rasterize " +
      "triangles with barycentric coordinates, composite with alpha, and kill the " +
      "staircase with supersampling. Then read the buffer back: brightness and " +
      "contrast as lookup tables, blur and Sobel edges as convolution kernels, " +
      "grayscale and sepia as colour matrices. Everything before the last chapter " +
      "runs in your browser.",
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
  },
  "building-libraries": {
    seoTitle: "Building Libraries in Zig",
    description:
      "Designing a real Zig library: an Ecto-style ORM built from comptime type " +
      "functions, with a typed query builder, migrations, transactions and a " +
      "swappable database adapter.",
    lede:
      "Longer than a recipe: one library, designed in the open, one decision per " +
      "chapter. The first is an Ecto-style ORM, which is a good stress test of " +
      "comptime because the schema is a type and every query is checked against " +
      "it before the program runs.",
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
      "ORM chapters under Building Libraries.",
  },
  "building-libraries/orm": {
    seoTitle: "Building an ORM in Zig",
    description:
      "An Ecto-style ORM in Zig: schemas as types, a typed query builder, " +
      "migrations as data, transactions with errdefer, and an adapter seam over " +
      "SQLite and PostgreSQL.",
    lede:
      "A database layer in the shape of Ecto: the schema is a type, the query " +
      "builder is checked at compile time against that type, migrations are data, " +
      "and the driver sits behind one seam so the same code runs on SQLite or " +
      "PostgreSQL.",
  },
};
