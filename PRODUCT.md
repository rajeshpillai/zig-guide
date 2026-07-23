# PRODUCT.md

Product truth for Zig Guide Live. Confirmed with the owner on 2026-07-23 unless
marked as an assumption.

## What it is

Zig Guide Live is a Zig tutorial site with one promise: **it is never stale**.
Every code snippet is compiled and executed by CI against current Zig master,
nightly, and the exact `.wasm` artifact CI verified is what the reader runs in
the browser. The site footer states the compiler version that actually verified
the snippets. There is no second code path; the docs are the code.

## Positioning

"The Zig guide that is never stale." The CI-verified freshness guarantee leads;
the in-browser playgrounds and cookbook practicality support it.

## Audience

Two first-class readers, weighted equally:

1. **Experienced developers new to Zig.** Fluent in C, C++, Rust, Go, or
   JavaScript; want to learn Zig properly with current APIs.
2. **Developers burned by stale Zig tutorials.** Tried Zig, hit compile errors
   from outdated guides, and need the current shape of the language. For them,
   the "what changed and why" deltas (e.g. the coming-from-older-zig page) are
   the most valuable content.

Not written for programming beginners; general programming literacy is assumed.

## Platform

`web`. A static Astro site, deployed to GitHub Pages under a base path
(default `/zig-guide/`). Mobile-first with a collapsible sidebar. Progressive
enhancement is a hard constraint: with JavaScript off, every snippet must
remain a readable highlighted code block.

## Mode

Read. The visitor is here to understand Zig. Structure serves comprehension
first; the playground invites verification, not spectacle.

## Surfaces

- **Chapters** (`web/src/content/docs/<section>/*.mdx`): Getting Started,
  Language Basics, Standard Library, Build System, Working with C, Cookbook.
- **Cookbook**: problem-first recipes (problem, plan, runnable solution,
  walkthrough, variations).
- **Playground**: a `<zig-playground>` custom element per snippet; runs the
  CI-verified wasm; CodeMirror editing loads only on demand.
- **Home page**: states the promise and the verifying compiler version.

## Voice

Careful human engineer. Concrete, specific, plain. Claims are phrased so the
reader (or the compiler) can check them. Detailed rules live in CLAUDE.md
under "Writing style"; the short form: no em dashes, no AI-flavored phrasing,
no throat-clearing, no hype.

## Visual identity

No commitments yet (confirmed 2026-07-23). The current look (minimal docs
layout, dark code blocks) is provisional and may be replaced by a deliberate
design pass later. Record any future world in DESIGN.md via the impeccable
new-work flow; do not treat the current CSS as brand.

## Non-goals

- Teaching general programming.
- Tracking stable Zig releases; the guide tracks master on purpose.
- A second, unverified code path (inline code fences that CI does not run are
  allowed only on the two pages that state their own unverifiability).

## Assumptions (labeled)

- Single author/owner; no team review flow for content.
- Readers arrive mostly via search and Zig community links; no analytics
  commitment has been made.
