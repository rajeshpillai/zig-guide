/**
 * The one ordering of the guide.
 *
 * The sidebar and the previous/next links at the foot of a page have to agree
 * about what comes after what. Deriving both from this module is what keeps
 * them from drifting: a chapter that moves in the sidebar moves in the pager
 * with it, and neither can be edited into a different order by hand.
 *
 * Three levels, and only the first two are URLs: track (from `TRACKS`) holds
 * sections (a top-level directory), which hold groups (one directory deeper)
 * or bare chapters.
 */
import { getCollection, type CollectionEntry } from "astro:content";
import { TRACKS, TRACK_OF } from "./tracks";

export type Doc = CollectionEntry<"docs">;

export interface NavGroup {
  /** Empty for the run of chapters that carry no `group`. */
  label: string;
  /** Directory the group lives in, which is also where its overview page is. */
  slug: string;
  members: Doc[];
}

export interface NavSection {
  title: string;
  slug: string;
  /** Ungrouped chapters first, then one bucket per `group` label. */
  groups: NavGroup[];
}

export interface NavTrack {
  title: string;
  blurb: string;
  sections: NavSection[];
}

/** A single stop on the linear walk through the guide. */
export interface Stop {
  /** Route param: a chapter's `id`, or a section or group directory. */
  id: string;
  href: string;
  title: string;
  /** Where the stop sits, shown above its title in the pager. */
  kicker: string;
}

const base = import.meta.env.BASE_URL;

/**
 * The one path segment every chapter lives under.
 *
 * The guide used to sit at the root, so a section owned a top-level word:
 * `/graphics/`, `/networking/`, `/how-to/`. Those are the words a page about
 * something other than a chapter would want, and taking one back after it has
 * ranked is the expensive move. One segment reserves the rest of the domain
 * and costs nothing: URL depth is not a ranking factor.
 *
 * `src/pages/learn.astro` is the index page for this segment and its filename
 * has to match. Nothing enforces that directly, but every breadcrumb links
 * here and the browser gate resolves every link on every page, so a rename of
 * one without the other fails `npm run e2e` rather than shipping a dead trail.
 */
export const GUIDE_SLUG = "learn";

/** The guide's own index page. */
export const guideHref = `${base}${GUIDE_SLUG}/`;

/** Route param for a chapter, section or group id. */
export const guideRoute = (id: string) => `${GUIDE_SLUG}/${id}`;

export const pageHref = (id: string) => `${guideHref}${id}/`;

/**
 * The whole guide, in sidebar order: chapters sorted by `order` within their
 * section, sections in the order `TRACKS` lists them, tracks in table order.
 */
export async function navTracks(): Promise<NavTrack[]> {
  const docs = await getCollection("docs");
  const sections = new Map<string, NavSection>();

  for (const doc of docs.sort((a, b) => a.data.order - b.data.order)) {
    const slug = doc.id.split("/")[0];
    const section = sections.get(slug) ?? { title: doc.data.section, slug, groups: [] };

    const label = doc.data.group ?? "";
    const group = section.groups.find((g) => g.label === label) ?? {
      label,
      slug: doc.id.split("/").slice(0, -1).join("/"),
      members: [],
    };
    if (!section.groups.includes(group)) section.groups.push(group);
    group.members.push(doc);

    sections.set(slug, section);
  }

  // Ungrouped first, then groups in first-appearance order.
  for (const section of sections.values()) {
    section.groups.sort((a, b) => (a.label === "" ? -1 : b.label === "" ? 1 : 0));
  }

  // A section missing from the table is a build error rather than a silent
  // default. Falling back would drop it at one end of the guide under whatever
  // heading happened to be last, which reads as deliberate and would survive
  // every check on this site: the pages build, the links resolve, the pager
  // walks. `SECTIONS` in seo.ts falls back instead because what it supplies is
  // copy; what this supplies is where the section is.
  const unplaced = [...sections.keys()].filter((slug) => !TRACK_OF.has(slug));
  if (unplaced.length > 0) {
    throw new Error(
      `Section(s) ${unplaced.join(", ")} are not listed in any track. ` +
        `Add them to TRACKS in src/tracks.ts, which is what orders the guide.`,
    );
  }

  return TRACKS.map((track) => ({
    title: track.title,
    blurb: track.blurb,
    sections: track.sections.flatMap((slug) => sections.get(slug) ?? []),
  }));
}

/** Every section, tracks flattened away, for the callers that want one list. */
export async function navSections(): Promise<NavSection[]> {
  return (await navTracks()).flatMap((track) => track.sections);
}

/**
 * Every page of the guide, flattened into the order a reader clicking "next"
 * would see them: a section's overview, then its ungrouped chapters, then each
 * group's overview followed by that group's chapters.
 */
export function readingOrder(sections: NavSection[]): Stop[] {
  const stops: Stop[] = [];

  for (const section of sections) {
    stops.push({
      id: section.slug,
      href: pageHref(section.slug),
      title: section.title,
      kicker: "Section",
    });

    for (const group of section.groups) {
      if (group.label) {
        stops.push({
          id: group.slug,
          href: pageHref(group.slug),
          title: group.label,
          kicker: section.title,
        });
      }
      for (const doc of group.members) {
        stops.push({
          id: doc.id,
          href: pageHref(doc.id),
          title: doc.data.title,
          kicker: group.label || section.title,
        });
      }
    }
  }

  return stops;
}

/** The stops either side of `id`; either end of the guide has one of them. */
export function neighbours(stops: Stop[], id: string): { prev?: Stop; next?: Stop } {
  const at = stops.findIndex((stop) => stop.id === id);
  if (at < 0) return {};
  return { prev: stops[at - 1], next: stops[at + 1] };
}
