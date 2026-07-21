# zig.guide (rebuilt) ⚡

A Zig tutorial where **every snippet is compiled and executed against current
Zig master on every build**, and where **readers run that same code in their
browser** — no server, no install, no sandbox.

The problem this solves: Zig moves fast. [zig.guide](https://zig.guide/) targets
0.15.2, and Zig has since shipped two sweeping breaking changes — the 0.15 I/O
overhaul (*"writergate"*) and the 0.16 migration of all filesystem APIs onto
`std.Io`. Documentation that is merely *proofread* rots silently. Documentation
that is **executed by CI** cannot.

If an example on this site were out of date, the build would be red.

---

## How the guarantee actually works

There is one artifact and it does two jobs.

```
snippets/*.zig
      │
      │  zig build verify      ← CI gate: compile + run + diff stdout
      ▼
  *.wasm  (wasm32-wasi)
      │
      │  zig build             ← install into web/public/wasm/
      ▼
web/public/wasm/*.wasm
      │
      │  fetch() + WASI shim   ← reader clicks "Run"
      ▼
  output in the browser
```

The `.wasm` the reader executes is **byte-identical** to the one CI compiled and
ran. There is no second code path that could drift, and no "docs say X, code
does Y" gap — the docs *are* the code.

Two runners implement the same WASI interface:

| Context | Runner | File |
| --- | --- | --- |
| CI / local | Node's `node:wasi` | [`tools/run-wasi.mjs`](tools/run-wasi.mjs) |
| Browser | `@bjorn3/browser_wasi_shim` | [`web/src/scripts/wasi-runner.ts`](web/src/scripts/wasi-runner.ts) |

A third gate closes the loop: [`web/tools/e2e-browser.mjs`](web/tools/e2e-browser.mjs)
drives the **built site** in headless Chromium, clicking Run on every playground,
asserting `exit 0`, and fetching every internal link.

### What the gate catches

All of these turn the build red — verified, not assumed:

| Failure | Example |
| --- | --- |
| **Stale API** | `std.fs.File.stdout()` after the `Io` migration → compile error |
| **Wrong behaviour** | a `test` that no longer passes → non-zero exit |
| **Drifted output** | stdout no longer matching the `.expected` file |
| **Broken page** | a playground that fails in a real browser |
| **Broken link** | an internal link that 404s |

The third one is subtler than it looks. An earlier version compared stdout via
`expectStdOutEqual`, and editing a `.expected` file did **not** invalidate the
build cache — a wrong expectation could sit there passing forever. Expected
files are now passed as tracked *file arguments*. Silent staleness is the one
bug class this project cannot tolerate.

### Snippets that cannot run in a browser

Two escape hatches, both of which keep the compile-time gate:

| Marker | Meaning | Used by |
| --- | --- | --- |
| `//! norun` | compiled, never executed | Runtime Safety (panics), Filesystem (no preopens) |
| `//! native` | built and run for the **host**, not wasm | Threads (`wasm32-wasi` is single-threaded, so `std.Thread.spawn` does not even compile) |

Both still fail the build on an API change. They simply render without a Run
button, with a note saying why.

---

## What's in it

58 chapters, mirroring zig.guide's structure, every one with CI-verified code:

| Section | Chapters |
| --- | --- |
| Getting Started | 3 |
| Language | 31 |
| Standard Library | 15 |
| Build System | 5 |
| Working with C | 4 |

Exactly one page — [Importing C](web/src/content/docs/working-with-c/cimport.mdx) —
shows code that is *not* CI-verified, because `@cImport` needs real headers and
a libc that the wasm sandbox does not have. The page says so.

---

## Quick start

Requires **Zig master** (see [Zig version](#zig-version)) and **Node 22+**.

```bash
./dev-start.sh
```

That is the whole dev loop. The script checks prerequisites, installs site
dependencies on first run, builds the snippet wasm, watches `snippets/` and
rebuilds on change, then serves the site at <http://localhost:4321>.

| Flag | Effect |
| --- | --- |
| `--verify` | run the full CI gate before serving, and on every snippet change |
| `--port N` | serve on a different port (default 4321) |
| `--host` | expose on the local network |
| `--no-watch` | don't rebuild snippets on change |
| `--clean` | discard generated artifacts first |

### Doing it by hand

```bash
zig build verify     # compile, run, and diff stdout for every snippet
zig build            # emit the wasm + manifest the site consumes
cd web && npm install && npm run dev
```

`zig build` must run before the site builds — the Astro build reads the manifest
that step produces, and fails with an explicit message if it is missing. This is
the ordering `dev-start.sh` exists to stop you getting wrong.

> Two things worth knowing about the dev server. Astro keeps a **lock file** and
> will silently attach to an already-running server instead of honouring
> `--port`; `dev-start.sh` stops any leftover server first. And Vite's
> dependency optimizer emits `504 (Outdated Optimize Dep)` in the console on
> early loads — that is dev-only noise, and the production build is clean.

---

## Repository layout

```
.
├── dev-start.sh               # start everything: build snippets, watch, serve
├── gh-deploy.sh               # verify, then publish web/dist to gh-pages
├── build.zig                  # the CI gate: walks snippets/, compiles, runs, verifies
├── build.zig.zon
├── snippets/                  # every line of Zig shown on the site
│   ├── 01-getting-started/
│   │   ├── hello-world.zig
│   │   └── hello-world.expected     # optional exact-stdout assertion
│   ├── 02-language/
│   │   └── _shapes.zig              # `_` prefix = helper module, not a snippet
│   ├── 03-standard-library/
│   ├── 04-build-system/
│   └── 05-working-with-c/
├── tools/
│   ├── run-wasi.mjs                 # Node-side WASI runner (CI)
│   └── build-browser-compiler.sh    # optional: builds zig.wasm for in-browser editing
├── web/                             # Astro site
│   ├── tools/e2e-browser.mjs        # headless-Chromium gate (npm run e2e)
│   ├── src/
│   │   ├── components/Playground.astro
│   │   ├── content/docs/<section>/*.mdx   # the prose; directory = URL namespace
│   │   ├── scripts/
│   │   │   ├── wasi-runner.ts       # runs prebuilt wasm in-browser
│   │   │   ├── playground.ts        # <zig-playground> custom element
│   │   │   ├── editor.ts            # lazy CodeMirror
│   │   │   └── zig-compiler.ts      # lazy in-browser Zig compiler
│   │   └── layouts/ styles/ pages/
│   └── public/wasm/                 # generated — do not edit, do not commit
└── .github/workflows/ci.yml         # verify + nightly + deploy
```

Content directories map to URL namespaces:
`content/docs/standard-library/allocators.mdx` → `/standard-library/allocators/`.
Each section also gets a generated index page, which is what the middle
breadcrumb link points at.

---

## Adding a snippet

1. Drop a `.zig` file in the appropriate `snippets/<chapter>/` directory.
2. Optionally add a sibling `.expected` file containing exact stdout.
3. Reference it from an `.mdx` page.

```bash
zig build verify   # confirm it compiles and runs
```

Classification is automatic and needs no configuration:

- contains `pub fn main` → built as an **executable**, stdout is captured
- otherwise → built as a **test binary**, `zig test`'s report is captured

The slug is `<chapter>.<filename>`, so `snippets/02-language/optionals.zig`
becomes `02-language.optionals`:

```mdx
---
title: Optionals
description: Zig's answer to null, checked by the compiler.
section: Language
order: 33
---

import Playground from "../../../components/Playground.astro";

<Playground name="02-language.optionals" />
```

`section` groups it in the sidebar and `order` sorts it. A snippet that cannot
run in the browser takes a `note` explaining why:

```mdx
<Playground name="03-standard-library.threads" note="Built and run natively by CI." />
```

The `//!` header comments in each snippet are metadata for the build and are
stripped before the code is shown to the reader.

Referencing a snippet that was never compiled is a **build error**, not a broken
page at runtime — the component validates the name against the generated
manifest and lists the valid ones.

---

## Frontend: why not HTMX (or React)

HTMX was considered and deliberately rejected. Its value is server-rendered
partial updates, and this site has no server:

- **The prose is static.** A static site generator emits it once; there is
  nothing for HTMX to swap.
- **The interactive part runs entirely client-side.** Compiling on a server
  would mean sandboxing untrusted native code, paying for a host, and rate
  limiting — a permanent operational burden, and a security surface, for a free
  docs site. Executing WebAssembly in the browser's own sandbox has none of
  those problems.

So the stack is **Astro + ~25 KB of vanilla TypeScript**. The playground is a
plain custom element (`<zig-playground>`), not a framework component.

It is also progressively enhanced: with JavaScript disabled, every snippet is
still a syntax-highlighted `<pre>` that reads correctly. The Run button is an
addition, never a prerequisite.

### Bundle budget

Code splitting is load-bearing here, not incidental:

| Chunk | Size | Loaded |
| --- | --- | --- |
| playground + WASI runner | ~25 KB | on any docs page |
| CodeMirror editor | ~514 KB | only when **Edit** is clicked |
| in-browser Zig compiler glue | ~2 KB | only when running *edited* code |

A reader who only presses **Run** never downloads the editor.

Snippets build as `ReleaseSmall` — 46–83 KB each. Note that `build.zig`
deliberately does *not* use `standardOptimizeOption`: that helper returns
`Debug` unless `-Drelease` is passed, which produced **1.4 MB** wasm files
(~30x larger) shipped to every reader. Override with `-Doptimize=Debug` when you
want stack traces in a snippet.

---

## The in-browser compiler (optional)

Unedited snippets run from their prebuilt wasm and need nothing extra. Editing a
snippet requires recompiling it, which means the Zig compiler itself must be
available as `wasm32-wasi` — the approach proven by
[zigtools/playground](https://github.com/zigtools/playground).

```bash
ZIG_SRC=/path/to/ziglang/zig tools/build-browser-compiler.sh
```

This emits `web/public/compiler/{zig.wasm,lib.tar}` (git-ignored, several MB).
Because no LLVM can exist inside a wasm compiler binary, this path depends on
Zig's **self-hosted wasm backend**.

> **Status: scaffolded, not yet verified.** The browser-side driver
> ([`zig-compiler.ts`](web/src/scripts/zig-compiler.ts)) — virtual FS, argv,
> diagnostics capture, reading the emitted module back out — is written and
> type-checks, but has not been run against a real `zig.wasm`, because building
> one is a long, memory-hungry compile. Until those artifacts exist, clicking
> **Edit** then **Run** fails with an explicit, actionable message and the rest
> of the site is unaffected. This is the one part of the repo that should be
> treated as unproven.

---

## Zig version

This guide tracks **Zig master**, not a stable release, and CI re-verifies every
snippet nightly against a fresh master build.

That is a treadmill by design: master breaks things, and the whole premise is
that breakage surfaces here before it surfaces for a reader. Expect to fix
snippets periodically — that is the maintenance cost of the guarantee.

Developed against `0.16.0-1449-g7faf6be353`. Note that your installed `zig` and
your `ziglang/zig` checkout can disagree; `zig version` is what actually builds.

### Divergences from the current zig.guide

Every one of these was found by the gate failing, not by reading release notes.
All are things a reader following zig.guide today would get wrong:

| Change | Now |
| --- | --- |
| `main` takes an argument | `pub fn main(init: std.process.Init) !void`; `init.io` is the `Io` instance |
| Writers are buffered | you must `flush`; the buffer belongs to the interface (0.15, *"writergate"*) |
| `std.fs.File` | `std.Io.File`, and every disk operation takes an `Io` (0.16) |
| **`**` array-repeat removed** | use `@splat`; `**` no longer tokenises, so `"-" ** 5` errors about whitespace around `*` |
| `ArrayList` / hash maps | unmanaged: `.empty`, allocator passed per call |
| `std.Thread.Mutex` | `std.Io.Mutex`, and `lock` takes an `io` |
| Custom `format` methods | take only a writer, and are invoked by `{f}`; `{t}` prints tag names |
| `comptime_float` | is `f128` — *not* arbitrary precision, unlike `comptime_int` |
| `addExecutable` | takes a `root_module`, not a source file directly |

The `**` one is the sharpest illustration of why this project exists: the
operator is simply gone, the resulting error message is misleading, and nothing
about reading the old tutorial would tell you.

---

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on push, PR, and a
06:00 UTC nightly schedule:

1. `zig build verify` — every snippet compiles, runs, and matches expected output
2. `zig build` — emit wasm + manifest
3. `npx astro build` — build the site
4. `npm run e2e` — every playground runs in headless Chromium, every link resolves
5. deploy to GitHub Pages (`main` only)

The nightly run is the point. A push-only CI proves the docs were correct when
last touched; the schedule proves they are correct *today*.

`SITE_URL` and `BASE_PATH` are job-level environment variables, defaulting to a
project site at `/zig-guide/`. Override them with repository variables if you
deploy elsewhere.

> **Set them in one place.** A project site embeds `BASE_PATH` in every absolute
> URL, so if the site is built with the prefix but the browser check is not told
> about it, every page 404s. Both read the same job-level variable for exactly
> this reason — the split version of this bug is what the first `gh-deploy.sh`
> dry run caught.

---

## Deploying

```bash
./gh-deploy.sh              # verify, build, publish to gh-pages
./gh-deploy.sh --dry-run    # everything except the push
./gh-deploy.sh --skip-e2e   # skip the browser pass
```

The script refuses to deploy from a dirty working tree, so a published site is
always traceable to a commit, and it runs the full gate — snippets, build,
browser — before pushing anything. `web/dist` goes to `gh-pages` as a single
orphan commit; the branch is a published artifact, not history.

If you use the Actions-based deployment in the workflow instead, pushing to
`main` is enough and this script is redundant.

---

## Status

Verified end-to-end in headless Chromium: **63 pages, 50 playgrounds all
exiting 0, 3 compile-only blocks, 69 internal links resolving, no console
errors.** Snippets execute in 2–20 ms.

- [x] Snippet pipeline: compile → run → diff stdout, every failure mode gated
- [x] Browser execution of prebuilt wasm, including `zig test` reports and exit codes
- [x] All 58 chapters across 5 sections
- [x] Breadcrumbs, section indexes, status bar, editor with Revert
- [x] CI with nightly master verification and a real-browser gate
- [x] Deploy script with a pre-flight gate

**Not done:**

- [ ] **In-browser compiler artifacts** — the one genuinely unproven piece
      (see the caveat above). Editing a snippet and pressing Run currently
      fails with an actionable message; everything else is unaffected.
- [ ] No search, no version switcher, no light theme

---

## License

MIT.
