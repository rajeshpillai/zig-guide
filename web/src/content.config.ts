import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

const docs = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/docs" }),
  schema: z.object({
    title: z.string(),
    /**
     * Overrides the <title> and the link-preview title without touching the
     * visible heading, the sidebar entry or the pager.
     *
     * A chapter is headed `JSON` because that is what it is, and every
     * chapter around it is named the same way. In a result list that heading
     * is competing with the whole web, and 224 of 228 chapter titles did not
     * contain the word Zig. The JSON chapter carried 142 impressions and no
     * clicks over the 36 days to 2026-08-30; a reader scanning for Zig had
     * nothing to scan for. Same mechanism as `seoTitle` in seo.ts, which does
     * this for section indexes, and same rule: it changes the tab and the
     * search result, never the page.
     */
    seoTitle: z.string().optional(),
    description: z.string().optional(),
    /**
     * Overrides the meta description without touching the line shown under
     * the chapter on its section index.
     *
     * The two want different lengths. On an index, `description` is one line
     * in a list of twenty and reads best at a handful of words. In a search
     * result it is the only sentence arguing for the click, and Google renders
     * about 155 characters: the median here was 72, so half the space was
     * being left empty. Same split as `SectionMeta`, where `description` is
     * the meta tag and `lede` is the visible copy.
     */
    seoDescription: z.string().optional(),
    /** Sort key within the sidebar; lower comes first. */
    order: z.number().default(999),
    /** Chapter grouping shown in the sidebar. */
    section: z.string(),
    /**
     * Optional sub-group within a section, for sections that host several
     * bodies of work (e.g. one per library under Building Libraries).
     * Grouped chapters render under a labelled sub-heading, after any
     * ungrouped chapters in the same section.
     */
    group: z.string().optional(),
  }),
});

/**
 * Dated posts at `/blog/<id>/`, outside the guide.
 *
 * A chapter is kept true: its code is gated every night against Zig master,
 * and it is rewritten when master moves. A post is the opposite kind of page.
 * It says what was true on the day it was written, and it is not rewritten
 * later. Both rules cannot apply to one page, so the post states which compiler
 * it was written against and the reader can judge its age.
 *
 * - `<Playground>` in a post is still gated, because the snippet lives in
 *   `snippets/` like any other. That code stays current.
 * - A plain fenced block is not gated, and neither `zig build verify` nor the
 *   deprecation check reads this directory. The post page says so next to
 *   the pinned version whenever the two compilers differ.
 */
const blog = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/blog" }),
  schema: z.object({
    title: z.string(),
    /** One line under the title on `/blog/`, and the meta description. */
    description: z.string(),
    /**
     * When the post went out: `YYYY-MM-DD`, or `YYYY-MM-DDTHH:MM` with an
     * explicit offset (`Z` or `+05:30`) when two posts share a day and the
     * order between them matters. Written by hand rather than taken from git:
     * a post drafted on `dev` for a week is published on the day it ships, not
     * on the day its first commit was made.
     *
     * The offset is required with a time because without one the build
     * machine's time zone would decide the instant, and CI runs in UTC. The
     * day shown is the day as written, in the author's offset, for the same
     * reason.
     */
    date: z
      .string()
      .regex(
        /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2}))?$/,
        "date must be YYYY-MM-DD, or YYYY-MM-DDTHH:MM with an offset such as +05:30",
      ),
    /**
     * The compiler the post was written against, exactly as `zig version`
     * prints it. Required, because a post with no version is the stale
     * tutorial this site exists to replace.
     */
    zig: z
      .string()
      .regex(/^\d+\.\d+\.\d+(-dev\.\d+\+[0-9a-f]+)?$/, "zig must be what `zig version` prints"),
    seoTitle: z.string().optional(),
  }),
});

export const collections = { docs, blog };
