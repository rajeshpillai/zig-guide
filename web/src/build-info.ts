/**
 * What `zig build` recorded about the build that verified the snippets.
 *
 * Read from the manifest rather than hardcoded anywhere, so the version on the
 * page is always the compiler that actually compiled and ran the snippets. Two
 * surfaces need it now (the footer on every page, and the what's-new page), and
 * a second `readFile` with a second fallback would be a second thing to keep
 * right.
 */
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

export interface BuildInfo {
  zigVersion: string;
  snippetCount: number;
}

/** Degrades rather than throwing: the site still builds before `zig build` has run. */
export async function buildInfo(): Promise<BuildInfo> {
  try {
    const info = JSON.parse(
      await readFile(resolve(process.cwd(), "public/wasm/build-info.json"), "utf8"),
    );
    return { zigVersion: info.zigVersion, snippetCount: info.snippetCount };
  } catch {
    return { zigVersion: "master", snippetCount: 0 };
  }
}
