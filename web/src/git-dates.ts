/**
 * When each page last changed, taken from git rather than from the filesystem.
 *
 * The sitemap's `lastmod` and a chapter's `dateModified` both have to mean
 * "when this content changed". Neither the file mtime nor the build clock says
 * that: a fresh checkout stamps every file with the checkout time, and this
 * site rebuilds every night whether or not a word moved. Publishing today's
 * date on all 145 chapters each morning is a freshness claim that is not true,
 * and search engines discount a `lastmod` they catch behaving that way, which
 * would cost us the one sitemap hint Google actually reads.
 *
 * One `git log` walk over the tracked sources gives both dates at once. The log
 * is newest-first, so the first time a path appears is its last edit and the
 * last time it appears is (near enough) when it was added; a rename shows the
 * pre-rename path in the older commits, which only affects the added date.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface PageDates {
  /** ISO 8601, from the most recent commit that touched the file. */
  modified: string;
  /** ISO 8601, from the oldest commit that touched the file. */
  published: string;
}

/** Matches the `%cI` committer date the log is formatted with. */
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/;

/**
 * The in-flight walk, not its result. Caching the map itself looks equivalent
 * and is not: `pageDates()` has to await `git log`, so a second caller arriving
 * during that await would be handed the map before it had been filled and would
 * conclude, silently and permanently, that nothing has a date. That is exactly
 * what happens when a caller fans out with `Promise.all` over 145 chapters, and
 * the symptom is a feed with one date in it rather than an error.
 */
let cache: Promise<Map<string, PageDates>> | null = null;

/**
 * Every tracked file under `web/src`, keyed by its path relative to `web/`
 * (which is what `entry.filePath` and Astro's own paths are relative to).
 *
 * Empty rather than throwing when git cannot answer. A tarball with no `.git`
 * still has to build, and every caller treats a missing date as "say nothing"
 * rather than substituting one. An absent `lastmod` is a non-signal, while a
 * wrong one is a lie a crawler will hold against the whole file.
 */
export function pageDates(): Promise<Map<string, PageDates>> {
  cache ??= walk();
  return cache;
}

async function walk(): Promise<Map<string, PageDates>> {
  const dates = new Map<string, PageDates>();

  // A shallow clone has one commit, so every file would come back with the
  // same date and the sitemap would claim the entire site changed at once.
  // That is worse than no dates, so bail rather than emit them. CI checks out
  // with `fetch-depth: 0` for exactly this reason.
  try {
    const { stdout } = await run("git", ["rev-parse", "--is-shallow-repository"]);
    if (stdout.trim() === "true") {
      console.warn(
        "[git-dates] shallow clone: omitting lastmod and article dates. " +
          "Set fetch-depth: 0 on actions/checkout to restore them.",
      );
      return dates;
    }
  } catch {
    console.warn("[git-dates] no git available: omitting lastmod and article dates.");
    return dates;
  }

  let stdout: string;
  try {
    ({ stdout } = await run(
      "git",
      ["log", "--format=%cI", "--name-only", "--no-merges", "--", "src"],
      // 145 chapters plus every page and script, over the repo's whole history.
      { maxBuffer: 64 * 1024 * 1024 },
    ));
  } catch (e) {
    console.warn(`[git-dates] git log failed, omitting dates: ${(e as Error).message}`);
    return dates;
  }

  let at = "";
  for (const line of stdout.split("\n")) {
    if (!line) continue;
    if (ISO.test(line)) {
      at = line;
      continue;
    }
    // Paths come back relative to the repo root; this module's callers work in
    // `web/`, which is also Astro's project root.
    const path = line.startsWith("web/") ? line.slice(4) : line;
    const seen = dates.get(path);
    if (seen) {
      // Still walking backwards, so this is a older commit than the last one
      // recorded for the file: it can only move the added date.
      seen.published = at;
    } else {
      dates.set(path, { modified: at, published: at });
    }
  }

  return dates;
}

/** The dates for one file, or undefined when git had nothing to say about it. */
export async function datesFor(path: string): Promise<PageDates | undefined> {
  return (await pageDates()).get(path);
}

/**
 * The most recent `modified` across several files.
 *
 * A section or group index has no file of its own: what it shows is the list of
 * chapters beneath it, so it changed when the newest of them did.
 */
export function newest(all: (PageDates | undefined)[]): string | undefined {
  const dates = all.filter((d): d is PageDates => Boolean(d)).map((d) => d.modified);
  if (dates.length === 0) return undefined;
  return dates.reduce((a, b) => (a > b ? a : b));
}
