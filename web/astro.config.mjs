import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import { rehypeBaseLinks } from "./plugins/rehype-base-links.mjs";

// `site` and `base` are overridden in CI for GitHub Pages project sites.
const base = process.env.BASE_PATH ?? "/";

export default defineConfig({
  site: process.env.SITE_URL ?? "http://localhost:4321",
  base,
  integrations: [mdx()],
  markdown: {
    shikiConfig: { theme: "github-dark", wrap: false },
    // Astro does not apply `base` to hrefs written by hand in content, so a
    // cross-chapter link would 404 on a project site without this.
    rehypePlugins: [[rehypeBaseLinks, { base }]],
  },
});
