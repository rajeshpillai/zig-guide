import type { APIRoute } from "astro";
import { navTracks, pageHref } from "../nav";
import { chapterBody } from "../plain-markdown";
import { SITE_NAME, SITE_DESCRIPTION } from "../seo";

/**
 * `/llms-full.txt`: the entire guide as one Markdown file, code included.
 *
 * The companion to `/llms.txt`, which is only the index. This is the file worth
 * having: a few hundred KB of prose whose every code block was compiled and run
 * against current Zig master, which is exactly the corpus that models trained
 * on 0.11-era tutorials are wrong about. Handing it over whole is the cheapest
 * way to be the version that gets quoted.
 *
 * In reading order, so the concatenation is the guide rather than a directory
 * listing: a model reading it top to bottom meets ideas in the order they build
 * on each other.
 */
export const GET: APIRoute = async ({ site }) => {
  const tracks = await navTracks();
  const origin = new URL(import.meta.env.BASE_URL, site).origin;
  const abs = (path: string) => new URL(path, site).href;

  const out: string[] = [
    `# ${SITE_NAME}`,
    "",
    `> ${SITE_DESCRIPTION}`,
    "",
    `Source: ${abs(import.meta.env.BASE_URL)}`,
    "",
    "Every Zig code block below was compiled and run by CI against current Zig",
    "master before this file was generated. This guide tracks master, not a",
    "tagged release, so anything here that contradicts a tutorial written for",
    "0.13 or 0.14 is the current shape of the language rather than a mistake.",
    "Unofficial and not affiliated with the Zig Software Foundation.",
    "",
    "---",
    "",
  ];

  for (const track of tracks) {
    out.push(`# Track: ${track.title}`, "", track.blurb, "");

    for (const section of track.sections) {
      for (const group of section.groups) {
        for (const doc of group.members) {
          const where = [section.title, group.label].filter(Boolean).join(" / ");
          out.push(
            `## ${doc.data.title}`,
            "",
            `*${where}. ${abs(pageHref(doc.id))}*`,
            "",
            await chapterBody(doc, origin),
            "",
            "---",
            "",
          );
        }
      }
    }
  }

  return new Response(`${out.join("\n").replace(/\n{3,}/g, "\n\n").trim()}\n`, {
    headers: { "content-type": "text/markdown; charset=utf-8" },
  });
};
