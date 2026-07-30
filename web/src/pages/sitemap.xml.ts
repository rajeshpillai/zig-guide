import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { datesFor, newest, type PageDates } from "../git-dates";
import { guideHref, pageHref } from "../nav";

/**
 * The sitemap, built from the same collection that builds the pages, so a new
 * chapter is listed the moment it exists. Hand-rolled rather than pulled from
 * an integration because the URL set here is not just "every file in
 * src/pages": most of the site is one dynamic route, and the section and group
 * indexes it generates have no file of their own to be discovered from.
 *
 * `lastmod` only. `changefreq` and `priority` used to be here and are gone:
 * Google states plainly that it ignores both, and emitting `daily` against 145
 * URLs that do not change daily is the pattern that teaches a crawler to
 * discount the file's hints wholesale, including the one hint it does read.
 * The dates come from git rather than the build clock for the same reason, and
 * a page git cannot date is emitted with no `lastmod` rather than with today's.
 */
export const GET: APIRoute = async ({ site }) => {
  const docs = await getCollection("docs");
  const base = import.meta.env.BASE_URL;

  const dated = new Map<string, PageDates | undefined>();
  for (const doc of docs) dated.set(doc.id, await datesFor(doc.filePath ?? ""));

  // Insertion order is the crawl order a reader would take.
  const urls = new Map<string, string | undefined>();
  const add = (path: string, lastmod?: string) => {
    if (!urls.has(path)) urls.set(path, lastmod);
  };

  // The home page and the guide index both list every section, so they are as
  // new as the newest thing they list.
  const everything = newest([...dated.values()]);
  add(base, everything);
  // The chapter list. Not a stop in the pager, so the walk would not reach it.
  add(guideHref, everything);
  // Not a chapter and not in the sidebar, so nothing else would list it.
  add(`${base}paths/`, await datesFor("src/pages/paths.astro").then((d) => d?.modified));
  // In the sidebar but not a chapter: it carries no pager, so the walk that
  // collects the chapters does not reach it either.
  add(
    `${base}references/`,
    await datesFor("src/pages/references.astro").then((d) => d?.modified),
  );
  // What's new lists every published change, so it is as new as the newest of
  // them rather than as new as its own source file.
  add(`${base}whats-new/`, everything);

  // A section or group index has no source file: it is the list of chapters
  // beneath it, so it changed when the newest of those did.
  const under = (prefix: string) =>
    newest(docs.filter((d) => d.id.startsWith(`${prefix}/`)).map((d) => dated.get(d.id)));

  const sections = new Set<string>();
  const groups = new Set<string>();
  for (const doc of docs) {
    sections.add(doc.id.split("/")[0]);
    if (doc.data.group) groups.add(doc.id.split("/").slice(0, -1).join("/"));
  }
  for (const slug of sections) add(pageHref(slug), under(slug));
  // A group whose chapters sit directly in the section directory resolves to
  // the section index, which `add` already holds; the dedupe keeps one entry.
  for (const slug of groups) add(pageHref(slug), under(slug));

  for (const doc of docs.sort((a, b) => a.data.order - b.data.order)) {
    add(pageHref(doc.id), dated.get(doc.id)?.modified);
  }

  add(`${base}privacy/`, await datesFor("src/pages/privacy.astro").then((d) => d?.modified));

  const body = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...[...urls].map(
      ([path, lastmod]) =>
        `  <url><loc>${new URL(path, site).href}</loc>` +
        (lastmod ? `<lastmod>${lastmod}</lastmod>` : "") +
        `</url>`,
    ),
    "</urlset>",
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "content-type": "application/xml; charset=utf-8" },
  });
};
