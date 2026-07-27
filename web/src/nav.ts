/**
 * The one ordering of the guide.
 *
 * The sidebar and the previous/next links at the foot of a page have to agree
 * about what comes after what. Deriving both from this module is what keeps
 * them from drifting: a chapter that moves in the sidebar moves in the pager
 * with it, and neither can be edited into a different order by hand.
 */
import { getCollection, type CollectionEntry } from "astro:content";

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

export const pageHref = (id: string) => `${base}${id}/`;

/**
 * Sections in sidebar order: chapters sorted by `order`, bucketed by section,
 * sections themselves in the order their first chapter appears.
 */
export async function navSections(): Promise<NavSection[]> {
  const docs = await getCollection("docs");
  const sections = new Map<string, NavSection>();

  for (const doc of docs.sort((a, b) => a.data.order - b.data.order)) {
    const slug = doc.id.split("/")[0];
    const section = sections.get(doc.data.section) ?? {
      title: doc.data.section,
      slug,
      groups: [],
    };

    const label = doc.data.group ?? "";
    const group = section.groups.find((g) => g.label === label) ?? {
      label,
      slug: doc.id.split("/").slice(0, -1).join("/"),
      members: [],
    };
    if (!section.groups.includes(group)) section.groups.push(group);
    group.members.push(doc);

    sections.set(doc.data.section, section);
  }

  // Ungrouped first, then groups in first-appearance order.
  for (const section of sections.values()) {
    section.groups.sort((a, b) => (a.label === "" ? -1 : b.label === "" ? 1 : 0));
  }

  return [...sections.values()];
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
