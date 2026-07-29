import type { APIRoute, GetStaticPaths } from "astro";
import { getCollection } from "astro:content";
import { guideRoute } from "../nav";
import { chapterMarkdown } from "../plain-markdown";

/**
 * The `.md` twin of every chapter URL: `/learn/language-basics/optionals.md`
 * beside `/learn/language-basics/optionals/`.
 *
 * Unlike `llms.txt` this is not a convention anyone has to have heard of. It is
 * one URL an agent can guess or follow from the `<link rel="alternate">` in the
 * page head, and what comes back is the chapter with its code and none of the
 * shell: no sidebar, no pager, no playground markup, no theme toggle. An agent
 * that fetches the HTML has to find the prose inside a page built to be read by
 * a person, and the part it most wants (the snippet) is a component reference
 * in the source rather than the program.
 *
 * Routed from the root rather than from a `learn/` directory in `src/pages/` so
 * that `GUIDE_SLUG` stays the only place the segment is named. `[...slug].astro`
 * never emits a path ending in `.md`, so the two catch-alls cannot collide.
 */
export const getStaticPaths: GetStaticPaths = async () => {
  const docs = await getCollection("docs");
  return docs.map((entry) => ({ params: { slug: guideRoute(entry.id) }, props: { entry } }));
};

export const GET: APIRoute = async ({ props, site }) => {
  const origin = new URL(import.meta.env.BASE_URL, site).origin;
  return new Response(await chapterMarkdown(props.entry, origin), {
    headers: { "content-type": "text/markdown; charset=utf-8" },
  });
};
