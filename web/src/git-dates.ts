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
 * last time it appears is (near enough) when it was added.
 *
 * The walk asks for `--name-status -M` rather than `--name-only`, so a rename
 * arrives as `R<score> <old> <new>` and the older commits touching `<old>` are
 * credited to the page they became. Without that, moving a chapter republishes
 * it: every commit before the move names a path nothing serves any more, so the
 * added date collapses onto the day it was moved. That is not hypothetical and
 * it is not small. This guide has reorganised four times and git already holds
 * 65 such renames, so before this every ORM chapter and every recipe that
 * changed section was telling crawlers it was first published on the day its
 * directory changed.
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
      ["log", "--format=%cI", "--name-status", "-M", "--no-merges", "--", "src"],
      // 145 chapters plus every page and script, over the repo's whole history.
      { maxBuffer: 64 * 1024 * 1024 },
    ));
  } catch (e) {
    console.warn(`[git-dates] git log failed, omitting dates: ${(e as Error).message}`);
    return dates;
  }

  // Old path to the path that content lives at now. Filled as the walk meets
  // each rename and read by every older commit that names the pre-rename path.
  // A file moved twice chains through it, which is why this resolves in a loop
  // rather than with a single lookup.
  const renamedTo = new Map<string, string>();
  const current = (path: string) => {
    let at = path;
    // Bounded by the map, and a cycle is impossible walking one direction
    // through history, but a malformed log should not hang the build.
    for (let hop = 0; hop < renamedTo.size + 1; hop++) {
      const next = renamedTo.get(at);
      if (next === undefined) return at;
      at = next;
    }
    return at;
  };

  // Paths come back relative to the repo root; this module's callers work in
  // `web/`, which is also Astro's project root.
  const relative = (path: string) => (path.startsWith("web/") ? path.slice(4) : path);

  let at = "";
  const touch = (path: string) => {
    const seen = dates.get(path);
    if (seen) {
      // Still walking backwards, so this is a older commit than the last one
      // recorded for the file: it can only move the added date.
      seen.published = at;
    } else {
      dates.set(path, { modified: at, published: at });
    }
  };

  for (const line of stdout.split("\n")) {
    if (!line) continue;
    if (ISO.test(line)) {
      at = line;
      continue;
    }
    // `--name-status` prefixes each path with its status and a tab: `M`, `A`,
    // `D`, and `R<score>` followed by two paths rather than one.
    const fields = line.split("\t");
    const status = fields[0];
    if (status.startsWith("R") && fields.length === 3) {
      const from = relative(fields[1]);
      const to = current(relative(fields[2]));
      renamedTo.set(from, to);
      touch(to);
      continue;
    }
    if (fields.length < 2) continue;
    touch(current(relative(fields[1])));
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
