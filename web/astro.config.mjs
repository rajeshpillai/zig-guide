import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import { rehypeBaseLinks } from "./plugins/rehype-base-links.mjs";
import { legacyRedirects } from "./legacy-urls.mjs";
import { indexableRedirects } from "./plugins/indexable-redirects.mjs";

// `site` and `base` are overridden in CI for GitHub Pages project sites.
const base = process.env.BASE_PATH ?? "/";
const redirects = legacyRedirects(base);

export default defineConfig({
  site: process.env.SITE_URL ?? "http://localhost:4321",
  base,
  integrations: [mdx(), indexableRedirects(redirects)],
  // Every address the guide has ever had, pointed at the page that replaced
  // it. Static output, so each one becomes a small HTML file with a zero-delay
  // meta refresh and a canonical link: GitHub Pages cannot issue a 301, and
  // this is what Google reads instead. See legacy-urls.mjs for how the table
  // is built and why the moves have to be written down rather than derived.
  // `indexableRedirects` above then takes `noindex` back off the emitted
  // pages, which is what lets Google pass the old address's ranking on.
  redirects,
  markdown: {
    // Two themes rather than one. `defaultColor: false` makes Shiki emit both
    // as CSS custom properties per token instead of baking one into a `color`,
    // which is what lets `global.css` pick a column with `light-dark()`. A
    // single github-dark block on a white page is the thing that makes a
    // retro-fitted light theme look unfinished, and on this site the code is
    // most of the page.
    shikiConfig: {
      themes: { light: "github-light-high-contrast", dark: "github-dark-high-contrast" },
      defaultColor: false,
      wrap: false,
    },
    // Astro does not apply `base` to hrefs written by hand in content, so a
    // cross-chapter link would 404 on a project site without this.
    rehypePlugins: [[rehypeBaseLinks, { base }]],
  },
});
