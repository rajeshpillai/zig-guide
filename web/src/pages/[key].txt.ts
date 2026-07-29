import type { APIRoute, GetStaticPaths } from "astro";
import { INDEXNOW_KEY } from "../indexnow";

/**
 * `/<key>.txt`, holding the key: how IndexNow checks that whoever submitted a
 * URL list for this host controls the host.
 *
 * A dynamic route rather than a file in `public/` because the filename *is* the
 * key, so a static file would be a second copy of it that could drift from
 * `src/indexnow.ts` in a rename. Both the file and the submissions read the one
 * constant, which is the only arrangement where they cannot disagree.
 *
 * On a project site this is served under the base path (`/zig-guide/<key>.txt`)
 * rather than at the host root, and that is deliberate. A key file authorises
 * the URLs at or below its own directory, every URL this site has is beneath
 * the base, and `tools/indexnow.mjs` sends that same path as `keyLocation`. The
 * two are built from `SITE_URL` and `BASE_PATH` on both sides, so the file and
 * the submission move together rather than one being pinned to the root.
 */
export const getStaticPaths: GetStaticPaths = () => [{ params: { key: INDEXNOW_KEY } }];

export const GET: APIRoute = () =>
  new Response(`${INDEXNOW_KEY}\n`, {
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
