/**
 * Festive decorations, and the one place a festival is defined.
 *
 * Each entry is a window of absolute instants. The offset is written into the
 * string, so every reader sees the garland appear at the same moment wherever
 * they are, rather than at local midnight in each timezone.
 *
 * Two checks decide whether a reader sees anything, and both are needed.
 *
 * The build emits the festival only when the build time falls inside the
 * window, widened by `LEAD_DAYS` before the start. Outside that, the page
 * carries no markup, no script and no reference to tinyfly at all. The nightly
 * CI build is what retires a festival: the first build after `end` drops every
 * trace of it without anyone remembering to.
 *
 * The inline script in `Base.astro` then checks the reader's clock against
 * the same two instants. A page built on the last evening still switches off
 * at `end`, and one built a few days early still waits for `start`.
 *
 * Adding the next festival is a row here plus its artwork in `global.css`
 * under `:root[data-festive="<id>"]`. The browser gate reads the window back
 * out of the page, so it needs no edit.
 */

export interface Festival {
  /** Written to `data-festive` on <html>. */
  id: string;
  /** Shown in the footer. */
  name: string;
  greeting: string;
  /** Inclusive. ISO 8601 with an explicit offset. */
  start: string;
  /** Exclusive, so the last day of the festival is the day before this. */
  end: string;
}

export const FESTIVALS: readonly Festival[] = [
  {
    // Ganesh Chaturthi to Anant Chaturdashi, the tenth-day Visarjan, in
    // India time.
    id: "ganesh",
    name: "Ganeshotsav",
    greeting: "Ganpati Bappa Morya",
    start: "2026-09-14T00:00:00+05:30",
    end: "2026-09-26T00:00:00+05:30",
  },
];

/** How early a build may start carrying a festival it will switch on later. */
const LEAD_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;

function instant(s: string, id: string, field: string): number {
  const ms = Date.parse(s);
  if (Number.isNaN(ms) || !/[+-]\d\d:\d\d$|Z$/.test(s)) {
    throw new Error(`festivals.ts: ${id}.${field} "${s}" is not an ISO instant with an offset`);
  }
  return ms;
}

// Checked once, when the module loads at build time. Two festivals at once
// would leave `data-festive` holding whichever came first with nothing saying
// so, and a window that ends before it starts would never show.
const windows = FESTIVALS.map((f) => ({
  f,
  from: instant(f.start, f.id, "start"),
  to: instant(f.end, f.id, "end"),
})).sort((a, b) => a.from - b.from);
for (const [i, w] of windows.entries()) {
  if (w.to <= w.from) throw new Error(`festivals.ts: ${w.f.id} ends before it starts`);
  const next = windows[i + 1];
  if (next && next.from < w.to) {
    throw new Error(`festivals.ts: ${w.f.id} overlaps ${next.f.id}`);
  }
}

// Build time only, like adsense.ts. No tsconfig in `web/`, so declare it.
declare const process: { env: Record<string, string | undefined> };

/**
 * The festival this build should carry, if any.
 *
 * `FESTIVE_BUILD_TIME` in the environment stands in for the clock, which is
 * how a build from before or after a festival is checked without editing a
 * date: `FESTIVE_BUILD_TIME=2026-10-01T00:00:00Z npm run build`.
 */
export function festivalForBuild(
  now: number = process.env.FESTIVE_BUILD_TIME
    ? instant(process.env.FESTIVE_BUILD_TIME, "FESTIVE_BUILD_TIME", "value")
    : Date.now(),
): Festival | null {
  const hit = windows.find((w) => now >= w.from - LEAD_DAYS * DAY_MS && now < w.to);
  return hit?.f ?? null;
}
