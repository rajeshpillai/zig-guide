import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";

// `site` and `base` are overridden in CI for GitHub Pages project sites.
export default defineConfig({
  site: process.env.SITE_URL ?? "http://localhost:4321",
  base: process.env.BASE_PATH ?? "/",
  integrations: [mdx()],
  markdown: {
    shikiConfig: { theme: "github-dark", wrap: false },
  },
});
