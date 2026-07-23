import type { APIRoute } from "astro";
import { ADSENSE_PUB_ID } from "../adsense";

/**
 * The authorized-sellers record Google reads from the site root. Generated
 * from the same publisher id the page script uses rather than kept as a
 * static file, because a mismatch between the two is silent: ads simply stop
 * being served, with nothing failing anywhere.
 *
 * `f08c47fec0942fa0` is Google's own certification authority id, identical
 * for every AdSense publisher.
 */
export const GET: APIRoute = () =>
  new Response(
    ADSENSE_PUB_ID ? `google.com, ${ADSENSE_PUB_ID}, DIRECT, f08c47fec0942fa0\n` : "",
    { headers: { "content-type": "text/plain; charset=utf-8" } },
  );
