import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { datesFor } from "../git-dates";
import { pageHref, guideHref } from "../nav";
import { SITE_NAME, SITE_DESCRIPTION, AUTHOR } from "../seo";

/**
 * A feed of chapters, newest change first.
 *
 * Not for the search engines: it is the discovery path that does not go through
 * one. Feeds get pulled into language newsletters and aggregators, which is how
 * a guide with no backlinks gets its first ones, and a reader who subscribes
 * finds out that a chapter was rewritten because Zig master moved without
 * having to check.
 *
 * Ordered by git commit date rather than by chapter number for that reason: the
 * interesting event on this site is a chapter *changing*, since the nightly is
 * what turns a compiler change into a content change.
 */

const escape = (s: string) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

export const GET: APIRoute = async ({ site }) => {
  const docs = await getCollection("docs");
  // Paths passed here already carry the base, as `pageHref` and `guideHref`
  // return them. A bare filename would resolve against the origin and lose the
  // prefix a project site is served under.
  const base = import.meta.env.BASE_URL;
  const abs = (path: string) => new URL(path, site).href;

  const items = (
    await Promise.all(
      docs.map(async (entry) => ({
        entry,
        dates: await datesFor(entry.filePath ?? ""),
      })),
    )
  )
    // Chapters git could not date sort last rather than dropping out: a feed
    // that silently omits a page is the failure mode this repo cares about.
    .sort((a, b) => (b.dates?.modified ?? "").localeCompare(a.dates?.modified ?? ""))
    .slice(0, 50);

  const body = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/">',
    "  <channel>",
    `    <title>${escape(SITE_NAME)}</title>`,
    `    <link>${abs(guideHref)}</link>`,
    `    <description>${escape(SITE_DESCRIPTION)}</description>`,
    "    <language>en</language>",
    `    <atom:link href="${abs(`${base}rss.xml`)}" rel="self" type="application/rss+xml" />`,
    ...items.flatMap(({ entry, dates }) => {
      const url = abs(pageHref(entry.id));
      return [
        "    <item>",
        `      <title>${escape(entry.data.title)}</title>`,
        `      <link>${url}</link>`,
        // The URL is stable and unique, and it is what a reader would open.
        `      <guid isPermaLink="true">${url}</guid>`,
        `      <description>${escape(entry.data.description ?? "")}</description>`,
        `      <category>${escape(entry.data.section)}</category>`,
        `      <dc:creator>${escape(AUTHOR)}</dc:creator>`,
        ...(dates ? [`      <pubDate>${new Date(dates.modified).toUTCString()}</pubDate>`] : []),
        "    </item>",
      ];
    }),
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "content-type": "application/rss+xml; charset=utf-8" },
  });
};
