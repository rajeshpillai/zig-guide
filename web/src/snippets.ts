/**
 * The `zig build` manifest, and the snippet sources it points at.
 *
 * Two things render a snippet now: the playground a reader clicks Run on, and
 * the plain-markdown copies an agent or a crawler fetches. Both have to show
 * the same text, so the manifest lookup and the `//!` header strip live here
 * rather than being written twice and drifting by one edit.
 */
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

export interface SnippetEntry {
  name: string;
  chapter: string;
  kind: "exe" | "test";
  /** Path to the `.zig`, relative to the repo root (one level above `web/`). */
  source: string;
  wasm: string;
  /** False when the snippet needs capabilities the browser sandbox lacks. */
  runnable: boolean;
}

// Anchored to the Astro project root (`web/`) rather than `import.meta.url`,
// which points into the bundle output once a component importing this is
// compiled.
const webRoot = process.cwd();

let manifest: Promise<SnippetEntry[]> | null = null;

export function snippetManifest(): Promise<SnippetEntry[]> {
  manifest ??= readFile(resolve(webRoot, "public/wasm/snippets.json"), "utf8")
    .then((text) => JSON.parse(text) as SnippetEntry[])
    .catch(() => {
      throw new Error(
        "web/public/wasm/snippets.json is missing. Run `zig build` at the repo " +
          "root before building the site.",
      );
    });
  return manifest;
}

export async function findSnippet(name: string): Promise<SnippetEntry> {
  const entries = await snippetManifest();
  const entry = entries.find((e) => e.name === name);
  if (!entry) {
    throw new Error(`Unknown snippet "${name}". Available: ${entries.map((e) => e.name).join(", ")}`);
  }
  return entry;
}

/**
 * A snippet's source as the reader sees it: the `//!` metadata header is for
 * `build.zig` to classify the file, not for anyone reading the chapter.
 */
export async function snippetSource(entry: SnippetEntry): Promise<string> {
  const source = await readFile(resolve(webRoot, "..", entry.source), "utf8");
  return source.replace(/^(\/\/!.*\n)+\n?/, "").trimEnd();
}
