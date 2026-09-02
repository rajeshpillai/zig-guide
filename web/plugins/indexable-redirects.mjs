/**
 * Take `noindex` off the redirect pages Astro emits for every legacy URL.
 *
 * Astro's redirect template carries `<meta name="robots" content="noindex">`
 * and `<link rel="canonical">` on the same page. The two contradict each
 * other, and Google resolves the contradiction in the direction that costs the
 * most here: `noindex` wins, the old address is dropped, and none of the
 * ranking it earned reaches the page that replaced it. On a host that can
 * issue a 301 the tag is harmless, because the crawler never sees the body.
 * GitHub Pages cannot, so the body is the whole redirect and every tag in it
 * is read.
 *
 * The bill arrived in Search Console. Over the 36 days to 2026-08-30, 5,027 of
 * 10,834 impressions were still on pre-`/learn/` addresses, 100 of those URLs
 * had no `/learn/` twin ranking at all, and where both ranked the old one
 * often ranked better: `/standard-library/formatting/` sat at position 17.3
 * while `/learn/standard-library/formatting/` sat at 33.5. That is one page
 * competing with itself, with the half Google was told to forget winning.
 *
 * The meta refresh and the canonical stay. Together they are a redirect Google
 * follows and consolidates; the third tag was the only one telling it not to.
 *
 * Astro's template is hardcoded with no hook to replace it, so this rewrites
 * the emitted files instead. That makes it a guess about someone else's
 * output, which is exactly the sort of guess that rots quietly, so it counts
 * what it changed and throws if a single redirect in the table did not match.
 * An Astro upgrade that retunes the template fails the build here rather than
 * restoring the tag on three hundred pages with nothing noticing.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const NOINDEX = '<meta name="robots" content="noindex">';

export function indexableRedirects(redirects) {
  return {
    name: "indexable-redirects",
    hooks: {
      "astro:build:done": ({ dir, logger }) => {
        const root = fileURLToPath(dir);
        const paths = Object.keys(redirects);
        const missed = [];
        let rewritten = 0;

        for (const from of paths) {
          const file = join(root, from.replace(/^\//, ""), "index.html");
          let html;
          try {
            html = readFileSync(file, "utf8");
          } catch {
            missed.push(`${from} (no file at ${file})`);
            continue;
          }

          if (!html.includes(NOINDEX)) {
            missed.push(`${from} (no noindex tag to remove)`);
            continue;
          }

          writeFileSync(file, html.replace(NOINDEX, ""));
          rewritten++;
        }

        if (missed.length) {
          throw new Error(
            `indexable-redirects: ${missed.length} of ${paths.length} redirect ` +
              `pages did not look like Astro's redirect template, so the ` +
              `noindex tag may still be on them. Astro's template has ` +
              `probably changed; check node_modules/astro/dist/core/routing/3xx.js ` +
              `against the NOINDEX constant here.\n  ` +
              missed.slice(0, 5).join("\n  ") +
              (missed.length > 5 ? `\n  ...and ${missed.length - 5} more` : ""),
          );
        }

        logger.info(`made ${rewritten} legacy redirects indexable`);
      },
    },
  };
}
