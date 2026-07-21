# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Zig tutorial site (Astro) where **every code snippet is compiled and executed by CI against current Zig master**, and where the *same* `.wasm` artifact CI ran is what the reader executes in their browser. There is deliberately no second code path — the docs *are* the code. Silent staleness is the one bug class this project cannot tolerate.

Requires **Zig master** (tracks master, not a stable release) and **Node 22+**.

## Commands

```bash
./dev-start.sh              # the whole dev loop: build snippets, watch, serve on :4321
./dev-start.sh --verify     # also run the full CI gate before serving and on each change
```

By hand — **order matters**, `zig build` must precede any web build:

```bash
zig build verify            # CI gate: compile + run + diff stdout for every snippet
zig build                   # emit wasm + snippets.json into web/public/wasm/
zig build -Doptimize=Debug  # when you need stack traces in a snippet
cd web && npm install && npm run dev
cd web && npm run build     # astro build
cd web && npm run e2e       # headless-Chromium gate: run every playground, check every link
cd web && npm run check     # astro check
```

There is no per-test runner: `zig build verify` walks all of `snippets/` in one step. To exercise a single snippet, run its wasm directly:

```bash
node tools/run-wasi.mjs web/public/wasm/02-language.optionals.wasm
```

Other scripts:

```bash
./update-zig.sh             # refresh toolchain then verify (--check, --force, --version X)
./gh-deploy.sh              # full gate then publish web/dist to gh-pages (--dry-run, --skip-e2e)
```

## Architecture

**The pipeline.** `snippets/*.zig` → `zig build verify` (compile, run under Node's `node:wasi`, diff stdout) → `zig build` installs the wasm + `snippets.json` manifest into `web/public/wasm/` → Astro reads the manifest at build time → the browser fetches the wasm and runs it through `@bjorn3/browser_wasi_shim`. Two runners, one WASI interface: [tools/run-wasi.mjs](tools/run-wasi.mjs) (CI) and [web/src/scripts/wasi-runner.ts](web/src/scripts/wasi-runner.ts) (browser).

**[build.zig](build.zig) is the gate.** It scans `snippets/` at configure time and classifies each file with no configuration:

- contains `pub fn main` → executable, stdout captured; otherwise → `zig test` binary
- sibling `<name>.expected` file → exact-stdout assertion
- `_`-prefixed filename → helper module, not a snippet
- `//! norun` → compiled but never run (panics, filesystem — still gates API drift)
- `//! native` → built and run for the **host** instead of wasm (threads: `wasm32-wasi` is single-threaded)

Slug is `<chapter-dir>.<filename>`, e.g. `02-language.optionals`. `//!` header comments are metadata and are stripped before the reader sees the code.

**Two non-obvious invariants in build.zig — do not "clean these up":**

1. Expected files are passed as tracked **file arguments** (`run.addFileArg`), not compared via `expectStdOutEqual`. The latter did not invalidate the build cache when a `.expected` file was edited, so a wrong expectation could pass forever.
2. It deliberately avoids `standardOptimizeOption` and defaults to `ReleaseSmall`. That helper returns `Debug` unless `-Drelease` is passed, which produced 1.4 MB wasm files (~30x) shipped to every reader.

**Web.** Astro + ~25 KB of vanilla TypeScript; no framework. The playground is a `<zig-playground>` custom element, progressively enhanced — with JS off every snippet is still a readable highlighted `<pre>`. Code splitting is load-bearing: CodeMirror (~514 KB) loads only on **Edit**, the compiler glue only when running edited code. `Playground.astro` validates the snippet name against `snippets.json` at build time, so a bad reference is a **build error**, not a runtime 404; it also fails with an explicit message when the manifest is missing.

Content lives in `web/src/content/docs/<section>/*.mdx`; the directory maps to the URL namespace. Frontmatter requires `title` and `section`, with optional `description` and `order` (sidebar sort). See [web/src/content.config.ts](web/src/content.config.ts).

`web/public/wasm/` and `web/public/compiler/` are generated — never edit or commit them.

## Working on this repo

- **Adding a snippet:** drop the `.zig` in `snippets/<chapter>/`, optionally add `.expected`, run `zig build verify`, then reference it from an `.mdx` page with `<Playground name="<chapter>.<file>" />`. Non-browser-runnable snippets take a `note="..."` explaining why.
- **When a Zig master change breaks a snippet** (the treadmill is the point): fix the snippet *and* update the chapter prose to teach the new shape while stating what the old one was. That delta is the most valuable content for a reader arriving from a stale tutorial — e.g. the arrays chapter explains that `**` is gone rather than silently switching to `@splat`.
- **The site footer version is emitted by `zig build`** — it is always the compiler that actually verified the snippets. There is no version string to bump anywhere.
- Only two pages are intentionally unverified, and both say so on the page: `working-with-c/cimport.mdx` (needs real headers/libc) and `getting-started/coming-from-older-zig.mdx` (its "before" examples deliberately do not compile).
- The in-browser Zig compiler (`web/src/scripts/zig-compiler.ts`, `tools/build-browser-compiler.sh`) is **blocked upstream** — `zig.wasm` cannot currently be built for `wasm32-wasi`. The browser driver is written and type-checks; do not pin to an older Zig to work around it, since the in-browser compiler must match the version the guide is verified against.

## CI and deployment

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on push, PR, and a 06:00 UTC nightly: `zig build verify` → `zig build` → `astro build` → `npm run e2e` → push `web/dist` to `gh-pages` (main only, only if all passed). The nightly is the point — it proves the docs are correct *today*, not when last touched.

- Pages is served from the **`gh-pages` branch**. Do not switch to `actions/deploy-pages` without also changing the repo Pages source, or the live site silently stops updating.
- Both `gh-deploy.sh` and CI publish as a fresh **orphan commit** of `web/dist`, so anything else on that branch is deleted.
**"Ship it"** means: work happens on `dev`, so fast-forward `main` onto `dev`, push `main` (that push is what deploys), then check `dev` back out and stay there.

```bash
git checkout main && git merge --ff-only dev && git push origin main && git checkout dev
```

If the fast-forward is refused, stop and report — do not merge or force-push without asking.

- `SITE_URL` and `BASE_PATH` are job-level env vars (default project site at `/zig-guide/`), read from one place by both the build and the browser check on purpose — a split would build with the prefix while checking without it and 404 every page.
