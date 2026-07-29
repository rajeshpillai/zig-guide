import type { APIRoute } from "astro";
import { navTracks, pageHref, guideHref } from "../nav";
import { SITE_NAME, SITE_DESCRIPTION, SECTIONS } from "../seo";

/**
 * `/llms.txt`: the guide's table of contents, for a model rather than a reader.
 *
 * The convention (llmstxt.org) is a single Markdown file at the root: an H1
 * name, a blockquote summary, then H2 sections of annotated links. A crawler
 * that fetches it gets the shape of the site in one request instead of
 * inferring it from 145 pages of HTML wrapped in a sidebar.
 *
 * This is a bet, not a standard, and it is cheap enough to be worth losing.
 * What is *not* a bet is the `.md` twin each link points at, which any agent
 * can fetch whether or not it has heard of this file.
 *
 * Generated from `navTracks()` like everything else that states an order, so a
 * new chapter appears here the moment it exists rather than when someone
 * remembers this file.
 */
export const GET: APIRoute = async ({ site }) => {
  const tracks = await navTracks();
  // Takes a path that already carries the base, which is what `pageHref` and
  // `guideHref` return; anything else has to be written with `base` in front of
  // it. A bare `"llms-full.txt"` here resolves against the origin and drops the
  // prefix, which is correct on the custom domain and a 404 on a project site.
  const base = import.meta.env.BASE_URL;
  const abs = (path: string) => new URL(path, site).href;

  // Point at the Markdown, not the HTML. The whole reason this file exists is
  // to save a fetcher from parsing a page shell it does not want.
  const md = (id: string) => abs(`${pageHref(id).replace(/\/$/, "")}.md`);

  const out: string[] = [
    `# ${SITE_NAME}`,
    "",
    `> ${SITE_DESCRIPTION}`,
    "",
    "Every snippet on this site is compiled and executed by CI against current",
    "Zig master on every build, including a nightly run against that day's",
    "compiler. Code here that no longer compiles fails the build and is fixed,",
    "so it does not go stale the way a tutorial pinned to an old release does.",
    "This tracks Zig master, not a tagged release, and it is an unofficial",
    "community guide with no affiliation to the Zig Software Foundation.",
    "",
    `Each chapter link below is the Markdown source. Replace \`.md\` with a`,
    `trailing slash for the HTML page, which additionally runs the snippets in`,
    `the browser as WebAssembly.`,
    "",
    `- [Full guide as one file](${abs(`${base}llms-full.txt`)}): every chapter concatenated, code included.`,
    `- [Chapter index](${abs(guideHref)}): the same list as HTML.`,
    "",
  ];

  for (const track of tracks) {
    out.push(`## ${track.title}`, "", `${track.blurb}`, "");

    for (const section of track.sections) {
      const meta = SECTIONS[section.slug];
      out.push(`### ${section.title}`, "");
      if (meta) out.push(meta.description, "");

      for (const group of section.groups) {
        if (group.label) out.push(`**${group.label}**`, "");
        for (const doc of group.members) {
          const desc = doc.data.description ? `: ${doc.data.description}` : "";
          out.push(`- [${doc.data.title}](${md(doc.id)})${desc}`);
        }
        out.push("");
      }
    }
  }

  return new Response(`${out.join("\n").replace(/\n{3,}/g, "\n\n").trim()}\n`, {
    headers: { "content-type": "text/markdown; charset=utf-8" },
  });
};
