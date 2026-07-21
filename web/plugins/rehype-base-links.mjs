/**
 * Prefix root-absolute links in Markdown/MDX with the site's base path.
 *
 * Astro applies `base` to its own asset URLs, but not to hrefs written by hand
 * in content. On a root-domain site that difference is invisible; on a GitHub
 * Pages *project* site every such link 404s. Doing it here means chapter
 * authors keep writing `/language-basics/slices/` and it stays correct
 * wherever the site is deployed.
 */
import { visit } from "unist-util-visit";

export function rehypeBaseLinks({ base = "/" } = {}) {
  const prefix = base.replace(/\/+$/, "");

  return (tree) => {
    if (!prefix) return;

    visit(tree, "element", (node) => {
      if (node.tagName !== "a") return;

      const href = node.properties?.href;
      if (typeof href !== "string") return;

      // Only root-absolute, same-site links. Leave external URLs, anchors,
      // protocol-relative links, and anything already prefixed alone.
      if (!href.startsWith("/")) return;
      if (href.startsWith("//")) return;
      if (href === prefix || href.startsWith(`${prefix}/`)) return;

      node.properties.href = prefix + href;
    });
  };
}
