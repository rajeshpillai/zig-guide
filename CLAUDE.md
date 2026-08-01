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
3. `simd128` is added **per snippet**, by the `//! simd` marker, and only for the four chapters that teach vectors. Without it `std.simd.suggestVectorLength` returns null, which silently compiles the SIMD path *out* of any snippet that guards on it (those chapters would ship scalar wasm while claiming otherwise) — so they need it. Nothing else may have it: `simd128` is a *target* feature, so enabling it globally makes LLVM auto-vectorize `std`'s memcpy and formatting paths, and hello-world shipped 159 v128 opcodes it never asked for. That made every one of the 118 snippets fail to validate on an engine without SIMD, which is a real population (SpiderMonkey disables wasm SIMD on x86 CPUs without SSE4.1, whatever the Firefox version) and was reported from the wild. `wasi-runner.ts` probes for SIMD and turns the resulting `unrecognized opcode: fd 0` into a message naming the requirement.

**Web.** Astro + ~25 KB of vanilla TypeScript; no framework. The playground is a `<zig-playground>` custom element, progressively enhanced — with JS off every snippet is still a readable highlighted `<pre>`. Code splitting is load-bearing: CodeMirror (~514 KB) loads only on **Edit**, the compiler glue only when running edited code. `Playground.astro` validates the snippet name against `snippets.json` at build time, so a bad reference is a **build error**, not a runtime 404; it also fails with an explicit message when the manifest is missing.

Content lives in `web/src/content/docs/<section>/*.mdx`; the directory maps to the URL namespace under `/learn/`. Cross-chapter links in prose are written root-absolute and include the segment: `[slices](/learn/language-basics/slices/)`. Frontmatter requires `title` and `section`, with optional `description` and `order` (sidebar sort). A section that hosts several bodies of work (Building Libraries, one per library) nests pages one directory deeper and labels them with optional `group`; grouped chapters render under a sub-heading in the sidebar and section index, after any ungrouped ones. See [web/src/content.config.ts](web/src/content.config.ts).

**One ordering.** [web/src/nav.ts](web/src/nav.ts) derives the track/section/group/chapter order, and everything that shows an order reads it: the sidebar, the home page, the guide index at [/learn/](web/src/pages/learn.astro), the routes and index listings in [[...slug].astro](web/src/pages/[...slug].astro), and the previous/next pager at the foot of every page.

**The root is not the chapter list.** [/](web/src/pages/index.astro) says what the site is and hands off; [/learn/](web/src/pages/learn.astro) is the full track and section listing. Duplicating the listing on both would leave two pages competing for the same searches with the same words, which is the whole reason the guide moved down a segment. The root is also where anything on this domain that is not a chapter goes.

[web/src/tracks.ts](web/src/tracks.ts) names the tracks (Foundations, Systems, Cookbook, Projects) and lists the sections in each, in order. **That table is the section ordering**, and a section missing from it fails the build rather than defaulting somewhere. Section order used to be emergent, sorted by whichever chapter carried the lowest `order`, which forced the number line to stay globally consistent and had already run out: Language Basics owned 10 through 40 and the Standard Library started at 15, so no integer was left to open a section between them, and the cookbook had reached `92.7` and `92.9` finding room for two recipes. `order` now sorts chapters within their own section and nothing else, so a new section is a table entry rather than a renumber.

**Every chapter lives under one segment, `/learn/`.** `GUIDE_SLUG` in [nav.ts](web/src/nav.ts) is that segment and `pageHref()` is the only thing that builds a page URL; the sidebar, breadcrumbs, pager, section indexes, sitemap, search index and reading paths all call it, so the prefix cannot be applied in five places and forgotten in a sixth. The guide used to sit at the root, which spent a top-level word on every section (`/graphics/`, `/networking/`, `/how-to/`) and left nothing for a page on this domain that is not a chapter. `src/pages/learn.astro` is the index for the segment and its filename has to match `GUIDE_SLUG`; nothing enforces that directly, but every breadcrumb links there and the browser gate resolves every link on every page, so a half-rename fails `npm run e2e`. **`/learn/` is a view of the guide, not a stop in it**, on the same terms as `/paths/`: it is absent from the sidebar and from `readingOrder()`, because a reader clicking "previous" out of the first chapter should reach the end of nothing, and a page in the sidebar is a page the gate expects to carry a pager.

**A track is never a URL segment.** Chapters stay at `/learn/orm/repo/`, not `/learn/projects/orm/repo/`, so tracks need no index page, `readingOrder()` emits no stop for one, and the linear walk and its pager gate are exactly what they were. **A project is a section, not a group** (the ORM is `/learn/orm/`, not `/learn/building-libraries/orm/`): groups stay for sub-parts inside a project, which keeps the tree three deep. Nesting a fourth level would not work anyway, since `[...slug].astro` emits index pages for a section slug and a group slug only, and a third directory level would leave a 404 in the middle of the breadcrumb. `readingOrder()` flattens it into the walk a reader following "Next" takes (a section's overview, its ungrouped chapters, then each group's overview and chapters), so moving a chapter moves it everywhere at once. The browser gate walks the whole chain: each "next" must be answered by the matching "previous", exactly two pages may be missing a link (the two ends), and following "next" from the first page must reach every page the sidebar lists. A pager that skipped a chapter or looped back would look perfectly reasonable on any single page.

The sidebar folds away on wide screens (the `rail-toggle` checkbox, so it works with JS off). Only the *persistence* is JavaScript: a short inline script in `Base.astro` restores the choice before the sidebar is parsed, because a deferred module would run after first paint and the sidebar would visibly flash open on every page.

[nav-state.ts](web/src/scripts/nav-state.ts) also scrolls the sidebar so the current chapter is visible. The sidebar is its own scroll container, so opening the right section is not enough: arriving from search or a link on a page far down the list would leave you looking at wherever the previous page left it. It sets `scrollTop` on the sidebar and never calls `scrollIntoView`, which would scroll the document too and move the chapter you just opened. The browser gate asserts both on every page: the active link is within the sidebar's visible band, and `window.scrollY` is still 0.

`web/public/wasm/` and `web/public/compiler/` are generated — never edit or commit them.

**Theming.** Two palettes, one set of tokens, in the `:root` block of [global.css](web/src/styles/global.css). Every colour is a `light-dark(light, dark)` pair, so each value is written once and switching themes is two one-line `color-scheme` rules rather than a duplicated block that drifts. The default is `color-scheme: light dark`, which means an untouched page follows the reader's system setting; `data-theme` on `<html>` exists only once someone overrides it.

- **Never hard-code a colour.** Six of them had accumulated outside the tokens and all six broke the moment a light theme existed. The tokens now cover the three surface depths (`--surface`, `--raised`, `--sunken`), `--on-accent` for text on an accent fill, and `--shadow`, because a shadow that reads on white is not the one that reads on near-black.
- **Zig amber cannot be link text on white** (2.04:1). The light column darkens it to `#8a5400`; `--on-accent` is the one token that inverts rather than lightens.
- **Code blocks are dual-themed too.** `defaultColor: false` in [astro.config.mjs](web/astro.config.mjs) makes Shiki emit `--shiki-light`/`--shiki-dark` per token instead of baking one in, and `global.css` picks a column with the same `light-dark()`. `Playground.astro` repeats the theme pair because `<Code>` takes it as a prop and does not read the markdown config. Both use the **high-contrast** GitHub themes: stock `github-dark` renders comments at 3.05:1, and on this site the comments in a snippet are prose.
- **The toggle is progressive enhancement**, on the same contract as the search box: `hidden` in the markup, revealed by [theme.ts](web/src/scripts/theme.ts). With JS off there is no toggle and the system setting still decides. Persistence is an inline `<head>` script, which has to run before the stylesheet resolves a single `light-dark()` or every page flashes the other theme.
- **`npm run e2e` measures contrast on the rendered page in both themes**, not on the stylesheet: only the browser resolves `light-dark()`, composites the translucent `color-mix` fills against what is behind them, and knows Shiki's per-token values. 82 assertions across three pages, AA thresholds with the large-text rule applied from the computed font size and weight. A palette edit that drops below AA is invisible to everyone except the readers who were already struggling, so nothing else would catch it.

**SEO.** All of it is derived, never hand-maintained per page. [web/src/seo.ts](web/src/seo.ts) holds the site name, description, author, preview-card path, and the hand-written copy for every section and group index (`seoTitle`, `description`, `lede`). `Base.astro` turns that plus the crumb trail into the `<title>`, meta description, canonical link, Open Graph and Twitter tags, and one JSON-LD graph per page (`WebSite` + `BreadcrumbList`, plus `TechArticle` on a chapter or `CollectionPage` on an index — the page supplies the type, the layout fills in every URL field so none can disagree with the canonical). [sitemap.xml.ts](web/src/pages/sitemap.xml.ts) and [robots.txt.ts](web/src/pages/robots.txt.ts) are generated endpoints, not files in `public/`, for the same reason `ads.txt` is: their URLs must be absolute, and the origin differs between the custom domain and a github.io project site.

- **`seoTitle` never changes the visible heading.** A section index is headed "Graphics" and titled "Zig Graphics: Software Rendering from Scratch". Adding a section without an entry in `SECTIONS` is not an error; the page just falls back to the chapter count, which is what every index said before. That is the opposite of the `TRACKS` rule above, on purpose: `SECTIONS` supplies copy, `TRACKS` supplies where the section is.
- **`takeaways` is the optional list above a section's chapter list.** Three to five claims a reader can carry away and check, ideally correcting something they arrived believing. Backticks in the string become `<code>`; everything else is escaped, so the copy stays plain strings rather than a second content format.
- **[/paths/](web/src/pages/paths.astro) is a view of the guide, not a stop in it.** Reading paths for five starting points, linked from the home page and the footer but deliberately not from the sidebar, which is the chapter list and whose links the browser gate treats as chapters that must carry a pager. Chapter ids there are resolved against the collection at build time and an unknown one throws, for the same reason `Playground.astro` validates snippet names.
- **The browser gate checks all of it.** `npm run e2e` asserts every page has a title, a meta description, an og:title, an og:image, exactly one `<h1>` and one valid JSON-LD block, and a canonical that names *that* page; that every page it reached is listed in `sitemap.xml` and every sitemap entry resolves; that `robots.txt` points at the real sitemap and does not disallow the site; and that `og.png` exists. None of this is visible on the page, so nothing else would ever notice it breaking.
- **`web/public/og.png` is generated by hand** with `npm run og --prefix web` (Playwright, already a dependency) and committed. It deliberately carries no version number or chapter count: a preview card is the one surface with no build watching it, so anything that changes nightly would be stale in it the next day.

## Working on this repo

- **Adding a snippet:** drop the `.zig` in `snippets/<chapter>/`, optionally add `.expected`, run `zig build verify`, then reference it from an `.mdx` page with `<Playground name="<chapter>.<file>" />`. Non-browser-runnable snippets take a `note="..."` explaining why.
- **Protocol code parses from a `Reader`, never from a socket.** That is why six of the ten Networking chapters run in the browser: the codec, the command parser and the connection handler take bytes and return bytes, and only `what-is-a-socket`, `tcp-echo`, `network-errors`, `udp-message` and `http-roundtrip` are `//! native`. It is also better design than the alternative, so apply it to anything protocol-shaped that follows (the planned Redis project depends on it).
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

**The Groundwork track (`systems-from-scratch/`) is the one place that explains from zero**, and it has two extra rules because plain-language teaching is where AI tone gets in.

- **An analogy must be paid off by the snippet on the same page.** Memory is a street of numbered houses, and the next block prints an actual address; a pointer is a scrap of paper with a house number, and the next block repaints the real door through it. An analogy that cannot be cashed out gets cut rather than extended. The register is Feynman, not a children's book: concrete and physical, still plain and still declarative, with no chirpy second person and no exclamation marks (the style rules above apply here unchanged).
- **Groundwork teaches the machine; Language Basics teaches the language.** What an address is, what a size costs, what it means to own memory: Groundwork. What `*T` means, that it is never null, how constness travels: Language Basics. Two pages on "pointers" that both explain pointers would compete for the same searches with the same words, which is the failure the `/learn/` move exists to avoid. Groundwork links forward to the Language Basics chapter at the foot of the page; Language Basics does not link back, so the pair reads as a progression rather than a loop.
- **Fixed page shape**, which is what keeps a long section from drifting in tone: the question, the idea in plain terms, the program (one complete `<Playground>`, never a fragment), what just happened, a "Check yourself" question, and an optional "If you have written C" aside. The C aside is always last and always optional, because the track assumes no C.
- **"Check yourself" must be answerable on the page**, and the page answers it in the next paragraph. It may not say "click Edit and Run": running edited code needs the in-browser compiler, which is blocked upstream, so today that path ends at a copy-source-and-leave escape hatch. That is an acceptable outcome for an expert poking at a snippet and a bad one for a beginner told to predict and check. Prose that instructs a reader to edit and run is a defect here until the compiler ships.
- **The shipped wasm is ReleaseSmall, so safety checks are compiled out of it.** A page may not claim "Zig catches this" next to a Run button that would not. Where a check is the lesson, say which build modes have it, ship the failing program as a `//! norun` snippet with a `note` and `tryLocally`, and never give it an `.expected` file whose content is the result of undefined behaviour.

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
