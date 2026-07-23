import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

const docs = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/docs" }),
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
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
