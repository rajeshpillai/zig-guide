import type { APIRoute } from "astro";
import { getCollection } from "astro:content";

/**
 * The sitemap, built from the same collection that builds the pages, so a new
 * chapter is listed the moment it exists. Hand-rolled rather than pulled from
 * an integration because the URL set here is not just "every file in
 * src/pages": most of the site is one dynamic route, and the section and group
 * indexes it generates have no file of their own to be discovered from.
 *
 * Priorities are deliberately coarse. Search engines treat them as a hint at
 * best, and a per-page number would be a knob nobody could ever tune.
 */
export const GET: APIRoute = async ({ site }) => {
  const docs = await getCollection("docs");
  const base = import.meta.env.BASE_URL;

  // Insertion order is the crawl order a reader would take.
  const urls = new Map<string, number>();
  const add = (path: string, priority: number) => {
    if (!urls.has(path)) urls.set(path, priority);
  };

  add(base, 1.0);
  // Not a chapter and not in the sidebar, so nothing else would list it.
  add(`${base}paths/`, 0.9);

  const sections = new Set<string>();
  const groups = new Set<string>();
  for (const doc of docs) {
    sections.add(doc.id.split("/")[0]);
    if (doc.data.group) groups.add(doc.id.split("/").slice(0, -1).join("/"));
  }
  for (const slug of sections) add(`${base}${slug}/`, 0.9);
  // A group whose chapters sit directly in the section directory resolves to
  // the section index, which `add` already holds; the dedupe keeps one entry.
  for (const slug of groups) add(`${base}${slug}/`, 0.8);

  for (const doc of docs.sort((a, b) => a.data.order - b.data.order)) {
    add(`${base}${doc.id}/`, 0.7);
  }

  add(`${base}privacy/`, 0.1);

  const body = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...[...urls].map(
      ([path, priority]) =>
        `  <url><loc>${new URL(path, site).href}</loc>` +
        `<changefreq>daily</changefreq>` +
        `<priority>${priority.toFixed(1)}</priority></url>`,
    ),
    "</urlset>",
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "content-type": "application/xml; charset=utf-8" },
  });
};
