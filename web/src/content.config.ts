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
  }),
});

export const collections = { docs };
