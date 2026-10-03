import type { APIRoute } from "astro";
import { blogHref, instant, postHref, posts, type Post } from "../../blog";
import { SITE_NAME, AUTHOR } from "../../seo";

/**
 * The blog's own feed, separate from `/rss.xml`.
 *
 * The two answer different questions. `/rss.xml` lists chapters as they
 * change, and most of its items are a chapter rewritten because Zig master
 * moved. This one lists posts once, on the day they go out. Mixing them would
 * bury a post under a night's worth of chapter fixes.
 */

const escape = (s: string) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

export const GET: APIRoute = async ({ site }) => {
  const abs = (path: string) => new URL(path, site).href;
  const rfc822 = (post: Post) => new Date(instant(post)).toUTCString();
  const list = await posts();

  const body = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" ' +
      'xmlns:dc="http://purl.org/dc/elements/1.1/">',
    "  <channel>",
    `    <title>${escape(`${SITE_NAME} blog`)}</title>`,
    `    <link>${abs(blogHref)}</link>`,
    `    <description>Posts about Zig, each written against a named compiler.</description>`,
    "    <language>en</language>",
    `    <atom:link href="${abs(`${blogHref}rss.xml`)}" rel="self" type="application/rss+xml" />`,
    ...(list[0] ? [`    <lastBuildDate>${rfc822(list[0])}</lastBuildDate>`] : []),
    ...list.map((post) =>
      [
        "    <item>",
        `      <title>${escape(post.data.title)}</title>`,
        `      <link>${abs(postHref(post))}</link>`,
        `      <guid isPermaLink="true">${abs(postHref(post))}</guid>`,
        `      <pubDate>${rfc822(post)}</pubDate>`,
        `      <dc:creator>${escape(AUTHOR)}</dc:creator>`,
        `      <description>${escape(`${post.data.description} Written against Zig ${post.data.zig}.`)}</description>`,
        "    </item>",
      ].join("\n"),
    ),
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "content-type": "application/rss+xml; charset=utf-8" },
  });
};
