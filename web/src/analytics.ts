/**
 * The one place the Google Analytics measurement id lives, for the same
 * reason [adsense.ts](./adsense.ts) exists: an id that appears twice is an id
 * that can disagree with itself. It is public either way, since it ships in
 * the page source.
 */
const MEASUREMENT_ID = "G-BJ00ZD18QB";

// This module runs at build time only. There is no tsconfig in `web/`, so
// declare the one global it needs rather than pull in @types/node for it.
declare const process: { env: Record<string, string | undefined> };

/**
 * Analytics are emitted by `astro build` and never by `astro dev`, so a dev
 * loop that reloads a page a hundred times does not report a hundred visits.
 *
 * `ANALYTICS_ID` in the environment overrides this: another property for a
 * fork, or an empty string to build the site with no analytics at all. As
 * with `ADSENSE_CLIENT`, do not wire that variable to a CI `vars.*`
 * expression, which resolves to `""` when unset and would silently deploy a
 * site that measures nothing.
 */
export const ANALYTICS_ID =
  process.env.ANALYTICS_ID ??
  (process.env.NODE_ENV === "production" ? MEASUREMENT_ID : "");
