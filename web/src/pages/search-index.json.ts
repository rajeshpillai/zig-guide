import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { pageHref } from "../nav";

/**
 * A build-time search index: one record per chapter, emitted as static JSON
 * the browser fetches on first use. No server, no third-party search service.
 * Kept small by stripping MDX/markdown to plain text and capping body length.
 */

/** MDX/markdown to searchable plain text. Order matters: links resolve to
 *  their text before punctuation is stripped. */
function plain(md: string): string {
  return md
    .replace(/^import\s.*$/gm, "") // MDX import lines
    .replace(/```[\s\S]*?```/g, (block) => block.replace(/```[\w-]*/g, " ")) // keep code words, drop fences
    .replace(/`([^`]+)`/g, "$1") // inline code
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ") // images
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1") // links to their text
    .replace(/<[^>]+>/g, " ") // JSX / HTML tags
    .replace(/^\s*[#>|:\-*]+\s?/gm, " ") // leading markdown markers
    .replace(/[*_`~#>|]/g, " ") // remaining inline markers
    .replace(/\s+/g, " ")
    .trim();
}

function headings(md: string): string[] {
  return [...md.matchAll(/^#{2,4}\s+(.+)$/gm)].map((m) =>
    m[1].replace(/[`*_]/g, "").trim(),
  );
}

export const GET: APIRoute = async () => {
  const docs = await getCollection("docs");

  const records = docs
    .sort((a, b) => a.data.order - b.data.order)
    .map((entry) => ({
      title: entry.data.title,
      section: entry.data.section,
      group: entry.data.group ?? null,
      description: entry.data.description ?? "",
      url: pageHref(entry.id),
      headings: headings(entry.body ?? ""),
      // Cap the body: enough to match on, small enough to ship the whole
      // index in one fetch.
      text: plain(entry.body ?? "").slice(0, 1600),
    }));

  return new Response(JSON.stringify(records), {
    headers: { "content-type": "application/json; charset=utf-8" },
  });
};
