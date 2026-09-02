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

export const collections = { docs };
