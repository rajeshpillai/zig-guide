/**
 * The one place the AdSense publisher id lives. Everything that needs it
 * (the loader script and the site verification meta tag in `Base.astro`, the
 * `ads.txt` record) reads it from here, so there is no second copy to fall
 * out of step. It is public either way: it ships in the page source and in
 * `/ads.txt`.
 */
const PUBLISHER = "ca-pub-6001451252012149";

// This module runs at build time only. There is no tsconfig in `web/`, so
// declare the one global it needs rather than pull in @types/node for it.
declare const process: { env: Record<string, string | undefined> };

/**
 * Ads are emitted by `astro build` and never by `astro dev`, so a dev loop
 * that reloads a page a hundred times is not repeatedly requesting live ads.
 *
 * `ADSENSE_CLIENT` in the environment overrides this: another publisher id
 * for a fork, or an empty string to build the site with no ad code at all.
 * An empty value disables every path, including `ads.txt`.
 */
export const ADSENSE_CLIENT =
  process.env.ADSENSE_CLIENT ??
  (process.env.NODE_ENV === "production" ? PUBLISHER : "");

/** `ca-pub-1234…` as Google writes it in ads.txt: `pub-1234…`. */
export const ADSENSE_PUB_ID = ADSENSE_CLIENT.replace(/^ca-/, "");
