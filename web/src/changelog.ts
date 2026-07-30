/**
 * What changed on this site, derived from the repository's own history.
 *
 * There is no hand-written changelog file, for the same reason there is no
 * hand-written version string: the two would drift, and the one that drifts is
 * always the one a human has to remember to edit. `git log` already records
 * every change that was published, in the order it was published, and CI
 * deploys from that history, so it cannot describe a release that did not
 * happen.
 *
 * What this loses is curation. Entries read the way commit subjects read, which
 * on this repo means a sentence about what changed and not marketing copy. What
 * it buys is that the page is correct without anyone maintaining it, including
 * on the nights when the only thing that changed was a snippet that stopped
 * compiling against Zig master, which is exactly the change a reader of this
 * site wants to hear about.
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
  chapters: Chapter[];
  /** Snippet slugs (`chapter.name`) whose source changed. */
  snippets: string[];
}

export interface Day {
  /** `YYYY-MM-DD`, the day these entries were committed. */
  date: string;
  entries: Entry[];
}

/**
 * Paths that never reach a reader. A commit touching only these shipped
 * nothing, and listing it would pad the page with planning notes and editor
 * configuration.
 */
const INVISIBLE = [
  "todo.md",
  "CLAUDE.md",
  "PRODUCT.md",
  "README.md",
  ".claude/",
  ".gitignore",
];

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

    // `A\tpath`, `M\tpath`, or `R100\told\tnew`: the path a rename produced is
    // the last field either way, and a rename is a move rather than an
    // addition however new the path looks.
    const changes = lines.slice(1).map((line) => {
      const fields = line.split("\t");
      return { status: fields[0][0], path: fields[fields.length - 1] };
    });
    if (changes.length === 0) continue;
    if (changes.every((c) => INVISIBLE.some((prefix) => c.path.startsWith(prefix)))) continue;

    const chapters: Chapter[] = [];
    const snippets: string[] = [];
    for (const { status, path } of changes) {
      // A deleted chapter has no page to link to and is not news that a reader
      // can act on; the commit subject is where a removal gets explained.
      if (status === "D") continue;
      const id = chapterOf(path);
      if (id) chapters.push({ id, added: status === "A" });
      const slug = snippetOf(path);
      if (slug) snippets.push(slug);
    }

    const entry: Entry = { iso, subject, chapters, snippets };

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

/** `snippets/14-os/pipes.zig` to `14-os.pipes`, or null. */
function snippetOf(path: string): string | null {
  const match = /^snippets\/([^/]+)\/([^/]+)\.zig$/.exec(path);
  if (!match) return null;
  // `_`-prefixed files are shared modules rather than snippets, the same rule
  // `build.zig` applies when it scans the directory.
  if (match[2].startsWith("_")) return null;
  return `${match[1]}.${match[2]}`;
}
