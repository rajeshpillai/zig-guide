/**
 * What was added to this guide, derived from the repository's own history.
 *
 * There is no hand-written changelog file, for the same reason there is no
 * hand-written version string: the two would drift, and the one that drifts is
 * always the one a human has to remember to edit. `git log` already records
 * what was published and when, and CI deploys from that history, so this cannot
 * describe a release that did not happen.
 *
 * **New chapters only.** An entry survives only if the commit added a page a
 * reader can now open. Everything else this repository does to itself is
 * excluded by that one rule: theming and layout work, CI and tooling, SEO
 * plumbing, refactors, planning notes, and the writing-style and house rules
 * that govern how the prose is produced. None of it is news to a reader, and
 * some of it is repository housekeeping that has no business on a public page
 * at all.
 *
 * The cost is that fixes do not appear, including the nights a snippet had to
 * be rewritten because Zig master moved. Those are visible per chapter as its
 * modified date, and in `rss.xml`, which orders by change rather than by
 * addition.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface Chapter {
  /** `section/chapter`, for the caller to resolve against the collection. */
  id: string;
  /** True only when this commit is the one that added the file. */
  added: boolean;
}

export interface Entry {
  /** Committer date, ISO 8601. */
  iso: string;
  /** First line of the commit message. */
  subject: string;
  /** The chapters this commit added. Never empty: an entry with none is dropped. */
  chapters: Chapter[];
}

export interface Day {
  /** `YYYY-MM-DD`, the day these entries were committed. */
  date: string;
  entries: Entry[];
}

/**
 * Subjects that never belong on a public page, whatever else the commit did.
 *
 * The "added a chapter" rule already excludes every one of these that exists
 * today, since none of them added a page. This is the backstop for the commit
 * that adds a chapter *and* changes how the repository is worked on in the same
 * breath: instructions to a coding agent, and the house rules about tone and
 * phrasing that shape the prose. A reader is here for Zig.
 */
const HIDDEN = /\b(claude|llm|gpt|copilot|ai[- ]?(tone|generated|flavou?red)|agent instructions|prompt)\b/i;

/** How far back to read. Older than this is history, not news. */
const LIMIT = 150;

const RECORD = "\x1e";
const FIELD = "\x1f";

let cache: Promise<Day[]> | null = null;

/** Published changes, newest day first. Empty when git cannot answer. */
export function changelog(): Promise<Day[]> {
  cache ??= walk();
  return cache;
}

async function walk(): Promise<Day[]> {
  let stdout: string;
  try {
    ({ stdout } = await run(
      "git",
      [
        "log",
        "--no-merges",
        `--max-count=${LIMIT}`,
        `--format=${RECORD}%cI${FIELD}%s`,
        // Status rather than names alone, so "added" is what git recorded and
        // not something inferred. Inferring it from a file's oldest commit
        // marks every chapter of a mass rename as new, because a rename is the
        // first time that path appears.
        "--name-status",
      ],
      { maxBuffer: 64 * 1024 * 1024 },
    ));
  } catch {
    // Same contract as `git-dates`: a checkout with no history still builds,
    // and the page says so rather than inventing entries.
    console.warn("[changelog] git log failed: the what's-new page will be empty.");
    return [];
  }

  const days = new Map<string, Entry[]>();

  for (const record of stdout.split(RECORD)) {
    const lines = record.split("\n").filter(Boolean);
    if (lines.length === 0) continue;

    const [iso, subject] = lines[0].split(FIELD);
    if (!iso || !subject) continue;
    if (HIDDEN.test(subject)) continue;

    // `A\tpath`, `M\tpath`, or `R100\told\tnew`: the path a rename produced is
    // the last field either way. A rename is a move however new the path looks,
    // so the commit that put every chapter under `/learn/` added nothing and
    // does not appear here.
    const chapters: Chapter[] = [];
    for (const line of lines.slice(1)) {
      const fields = line.split("\t");
      if (fields[0][0] !== "A") continue;
      const id = chapterOf(fields[fields.length - 1]);
      if (id) chapters.push({ id, added: true });
    }

    // Nothing a reader can open is nothing to announce.
    if (chapters.length === 0) continue;

    const entry: Entry = { iso, subject, chapters };

    const date = iso.slice(0, 10);
    const bucket = days.get(date);
    if (bucket) bucket.push(entry);
    else days.set(date, [entry]);
  }

  // `git log` is already newest first, and a Map keeps insertion order.
  return [...days].map(([date, entries]) => ({ date, entries }));
}

const DOCS = "web/src/content/docs/";

/** `web/src/content/docs/os/pipes.mdx` to `os/pipes`, or null. */
function chapterOf(path: string): string | null {
  if (!path.startsWith(DOCS)) return null;
  const rest = path.slice(DOCS.length);
  const dot = rest.lastIndexOf(".");
  return dot === -1 ? rest : rest.slice(0, dot);
}

