/**
 * The `zig build` manifest, and the snippet sources it points at.
 *
 * Two things render a snippet now: the playground a reader clicks Run on, and
 * the plain-markdown copies an agent or a crawler fetches. Both have to show
 * the same text, so the manifest lookup and the `//!` header strip live here
 * rather than being written twice and drifting by one edit.
 */
import { readFile } from "node:fs/promises";
import { statSync } from "node:fs";
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
  /**
   * True for `//! fails` snippets: built with safety checks on and required by
   * CI to stop with a specific message. Running one is supposed to end
   * non-zero, so the browser gate has to expect the opposite of what it
   * expects everywhere else.
   */
  expectFail: boolean;
}

// Anchored to the Astro project root (`web/`) rather than `import.meta.url`,
// which points into the bundle output once a component importing this is
// compiled.
const webRoot = process.cwd();

const manifestPath = resolve(webRoot, "public/wasm/snippets.json");

let manifest: Promise<SnippetEntry[]> | null = null;
let manifestStamp = -1;

/**
 * Cached, but keyed on the file's mtime rather than the process lifetime.
 *
 * `astro build` reads this once per page, so it has to be cached: 174 pages
 * re-parsing the manifest is work for nothing. But `dev-start.sh` runs a
 * watcher that reruns `zig build` while `astro dev` owns the foreground, so
 * during a dev session the manifest is regenerated under a process that never
 * restarts. Caching for the process lifetime meant a snippet added mid-session
 * was invisible until you noticed and restarted the server, and the error it
 * produced ("Unknown snippet", followed by every name except the new one)
 * pointed at the page rather than at the staleness.
 *
 * One `stat` per lookup is cheap next to the `readFile` it replaces.
 */
export function snippetManifest(): Promise<SnippetEntry[]> {
  let stamp = manifestStamp;
  try {
    stamp = statSync(manifestPath).mtimeMs;
  } catch {
    // Missing or unreadable: fall through so the read below owns the error
    // message, which names the command that produces the file.
    stamp = -1;
  }

  if (manifest === null || stamp !== manifestStamp) {
    manifestStamp = stamp;
    manifest = readFile(manifestPath, "utf8")
      .then((text) => JSON.parse(text) as SnippetEntry[])
      .catch(() => {
        throw new Error(
          "web/public/wasm/snippets.json is missing. Run `zig build` at the repo " +
            "root before building the site.",
        );
      });
  }
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
