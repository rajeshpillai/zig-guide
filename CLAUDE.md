# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Zig tutorial site (Astro) where **every code snippet is compiled and executed by CI against current Zig master**, and where the *same* `.wasm` artifact CI ran is what the reader executes in their browser. There is deliberately no second code path — the docs *are* the code. Silent staleness is the one bug class this project cannot tolerate.

Requires **Zig master** (tracks master, not a stable release) and **Node 24+**. Node 22 segfaults inside `node:wasi` on about 1% of runs of the `06-cookbook.serialization-size` snippet, which made the nightly fail on an unchanged tree; CI pins 24 for that reason and the comment in `ci.yml` records the measurement.

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
- `//! norun` **on a native snippet** → compiled and linked for the host, never run. This is what lets the X11 chapter link against the real libX11 (so translate-c drift fails the build) without CI sitting through a window waiting for a keypress.

Slug is `<chapter-dir>.<filename>`, e.g. `02-language.optionals`. `//!` header comments are metadata and are stripped before the reader sees the code.

**Three non-obvious invariants in build.zig — do not "clean these up":**

1. Expected files are passed as tracked **file arguments** (`run.addFileArg`), not compared via `expectStdOutEqual`. The latter did not invalidate the build cache when a `.expected` file was edited, so a wrong expectation could pass forever.
2. It deliberately avoids `standardOptimizeOption` and defaults to `ReleaseSmall`. That helper returns `Debug` unless `-Drelease` is passed, which produced 1.4 MB wasm files (~30x) shipped to every reader.
3. The wasm target adds the `simd128` CPU feature. Without it `std.simd.suggestVectorLength` returns null, which silently compiles the SIMD path *out* of any snippet that guards on it (the SIMD chapters would ship scalar wasm while claiming otherwise). Every supported browser and Node implement simd128.

**Web.** Astro + ~25 KB of vanilla TypeScript; no framework. The playground is a `<zig-playground>` custom element, progressively enhanced — with JS off every snippet is still a readable highlighted `<pre>`. Code splitting is load-bearing: CodeMirror (~514 KB) loads only on **Edit**, the compiler glue only when running edited code. `Playground.astro` validates the snippet name against `snippets.json` at build time, so a bad reference is a **build error**, not a runtime 404; it also fails with an explicit message when the manifest is missing.

Content lives in `web/src/content/docs/<section>/*.mdx`; the directory maps to the URL namespace. Frontmatter requires `title` and `section`, with optional `description` and `order` (sidebar sort). A section that hosts several bodies of work (Building Libraries, one per library) nests pages one directory deeper and labels them with optional `group`; grouped chapters render under a sub-heading in the sidebar and section index, after any ungrouped ones. See [web/src/content.config.ts](web/src/content.config.ts).

`web/public/wasm/` and `web/public/compiler/` are generated — never edit or commit them.

**SEO.** All of it is derived, never hand-maintained per page. [web/src/seo.ts](web/src/seo.ts) holds the site name, description, author, preview-card path, and the hand-written copy for every section and group index (`seoTitle`, `description`, `lede`). `Base.astro` turns that plus the crumb trail into the `<title>`, meta description, canonical link, Open Graph and Twitter tags, and one JSON-LD graph per page (`WebSite` + `BreadcrumbList`, plus `TechArticle` on a chapter or `CollectionPage` on an index — the page supplies the type, the layout fills in every URL field so none can disagree with the canonical). [sitemap.xml.ts](web/src/pages/sitemap.xml.ts) and [robots.txt.ts](web/src/pages/robots.txt.ts) are generated endpoints, not files in `public/`, for the same reason `ads.txt` is: their URLs must be absolute, and the origin differs between the custom domain and a github.io project site.

- **`seoTitle` never changes the visible heading.** A section index is headed "Graphics" and titled "Zig Graphics: Software Rendering from Scratch". Adding a section without an entry in `SECTIONS` is not an error; the page just falls back to the chapter count, which is what every index said before.
- **The browser gate checks all of it.** `npm run e2e` asserts every page has a title, a meta description, an og:title, an og:image, exactly one `<h1>` and one valid JSON-LD block, and a canonical that names *that* page; that every page it reached is listed in `sitemap.xml` and every sitemap entry resolves; that `robots.txt` points at the real sitemap and does not disallow the site; and that `og.png` exists. None of this is visible on the page, so nothing else would ever notice it breaking.
- **`web/public/og.png` is generated by hand** with `npm run og --prefix web` (Playwright, already a dependency) and committed. It deliberately carries no version number or chapter count: a preview card is the one surface with no build watching it, so anything that changes nightly would be stale in it the next day.

## Working on this repo

- **Adding a snippet:** drop the `.zig` in `snippets/<chapter>/`, optionally add `.expected`, run `zig build verify`, then reference it from an `.mdx` page with `<Playground name="<chapter>.<file>" />`. Non-browser-runnable snippets take a `note="..."` explaining why.
- **When a Zig master change breaks a snippet** (the treadmill is the point): fix the snippet *and* update the chapter prose to teach the new shape while stating what the old one was. That delta is the most valuable content for a reader arriving from a stale tutorial — e.g. the arrays chapter explains that `**` is gone rather than silently switching to `@splat`.
- **The site footer version is emitted by `zig build`** — it is always the compiler that actually verified the snippets. There is no version string to bump anywhere.
- Only two pages are intentionally unverified, and both say so on the page: `working-with-c/cimport.mdx` (needs real headers/libc) and `getting-started/coming-from-older-zig.mdx` (its "before" examples deliberately do not compile).
- The in-browser Zig compiler (`web/src/scripts/zig-compiler.ts`, `tools/build-browser-compiler.sh`) is **blocked upstream** — `zig.wasm` cannot currently be built for `wasm32-wasi`. The browser driver is written and type-checks; do not pin to an older Zig to work around it, since the in-browser compiler must match the version the guide is verified against.

## Writing style

Applies to everything a reader sees: `.mdx` prose, snippet comments, page copy, home-page text. The voice is a careful human engineer: concrete, specific, plain. Nothing a reader sees may carry an AI or LLM tone: no assistant-style hedging, framing, or summary voice, no "as an AI", no generic upbeat filler. Every page must read as if a human engineer wrote it by hand. Detectable AI-generated phrasing is a defect in this repo, on the same footing as a broken snippet.

- **No em dashes (—) or en dashes (–) in prose.** Rewrite the sentence instead: split it, or use a colon, comma, or parentheses. Hyphens in compound words are fine.
- **Banned phrasing:** "delve", "dive into", "seamless(ly)", "leverage" (as a verb), "robust", "powerful", "unlock", "elevate", "supercharge", "landscape", "game-changer", "journey", "excited to", and any "it's not just X, it's Y" construction.
- **No throat-clearing.** Never open with "In this section we will..." or "Let's explore...". State the fact.
- **No hype punctuation:** no exclamation marks in prose, no emoji, no rhetorical questions as section openers.
- **Prefer short declarative sentences** over rule-of-three flourishes and adjective stacks. When a claim can be checked by the compiler or the reader, phrase it so they can check it.

The impeccable skill (`.claude/skills/impeccable/`) is installed for design work on the site; product truth lives in [PRODUCT.md](PRODUCT.md).

## CI and deployment

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on push, PR, and a 06:00 UTC nightly: `zig build verify` → `zig build` → `astro build` → `npm run e2e` → push `web/dist` to `gh-pages` (main only, only if all passed). The nightly is the point — it proves the docs are correct *today*, not when last touched.

- Pages is served from the **`gh-pages` branch**. Do not switch to `actions/deploy-pages` without also changing the repo Pages source, or the live site silently stops updating.
- Both `gh-deploy.sh` and CI publish as a fresh **orphan commit** of `web/dist`, so anything else on that branch is deleted.
**"Ship it"** means: work happens on `dev`, so first push `dev` to its remote (keeping `origin/dev` in sync), then fast-forward `main` onto `dev` and push `main` (that push is what deploys to `gh-pages` via CI), then check `dev` back out and stay there. Both remote branches end up matching local; the deploy follows from the `main` push.

```bash
git push origin dev && git checkout main && git merge --ff-only dev && git push origin main && git checkout dev
```

If the fast-forward is refused, stop and report — do not merge or force-push without asking.

- **Ads.** The AdSense publisher id lives in exactly one place, [web/src/adsense.ts](web/src/adsense.ts), read by both the head tags in `Base.astro` and the generated [web/src/pages/ads.txt.ts](web/src/pages/ads.txt.ts). Keeping `ads.txt` generated rather than static matters: if it and the page tag disagreed, ad serving would just stop, with nothing failing anywhere. Ads are emitted by `astro build` and never by `astro dev`. `ADSENSE_CLIENT` in the environment overrides the id, and an **empty** value disables every ad path — so do not wire that env var to a CI `vars.*` expression, which resolves to `""` when unset and would silently deploy an ad-free site. Placement is auto ads, controlled from the AdSense dashboard, so there is no per-page markup; a manual-slot component would import the same constant. The browser gate stubs the ad domains with an empty 200 (not an abort, which logs a console error) so it never waits on an ad auction. `/privacy` is required by AdSense policy and is linked from the footer.
- **Analytics.** Google Analytics 4, wired the same way and for the same reasons: the measurement id lives only in [web/src/analytics.ts](web/src/analytics.ts), it is emitted by `astro build` and never by `astro dev`, and `ANALYTICS_ID` in the environment overrides it with an **empty** value disabling it entirely — the same CI `vars.*` trap applies. The inline config block sets `window.gtag` rather than declaring `function gtag()` as Google's snippet does, because `define:vars` wraps the block in an IIFE that would keep the declaration out of the global scope; pageviews would still record while any later `gtag("event", …)` call threw. Astro serves every page as its own document, so there is no client-side routing for gtag to miss. The browser gate stubs `googletagmanager`/`google-analytics` alongside the ad domains, so a gate run never reports itself as traffic. Anything measured here has to be described on `/privacy`.

  **Pending change: ads below the footer only.** The intent is that no ad appears inline in a chapter body, because auto ads inject units between prose blocks and around the playground, which is the reading flow the guide exists to protect. Not implemented, and it cannot be done from this repo alone. Two things have to happen together, and doing either one on its own fails silently:

  1. **Turn auto ads off** for the domain in the AdSense dashboard. Left on, units keep appearing inline whatever the markup says, and the repo has no way to detect or override that.
  2. **Add one manual display unit after `</footer>`** in `Base.astro`. This needs a `data-ad-slot` value that only the dashboard can issue, which is what the change is currently blocked on.

  When building it: read the publisher id from [web/src/adsense.ts](web/src/adsense.ts) rather than hardcoding it, so `ads.txt` and the page tag cannot drift apart; keep the empty-`ADSENSE_CLIENT` escape hatch working, so an unset id still emits no ad markup at all; and expect no measurable revenue from the position, since few readers scroll past the end of a chapter. A single unit between the chapter body and the footer is the compromise worth raising if the goal turns out to be fewer interruptions rather than none.
- `SITE_URL` and `BASE_PATH` are job-level env vars, read from one place by both the build and the browser check on purpose — a split would build with the prefix while checking without it and 404 every page. They default to the custom domain `https://www.ziglang.in` served at the root (`/`); repo variables `vars.SITE_URL`/`vars.BASE_PATH` override, e.g. `BASE_PATH=/zig-guide/` to fall back to the `github.io` project site. The custom domain is pinned by `web/public/CNAME`, which Astro copies into `dist/` so it survives the orphan-commit deploy that would otherwise wipe it.
