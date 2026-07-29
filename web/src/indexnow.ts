/**
 * The IndexNow key, in one place, for the same reason the AdSense id is.
 *
 * IndexNow is a push: instead of waiting to be crawled, the deploy tells Bing
 * (and Yandex, Seznam, Naver) which URLs just changed, and they fetch those
 * rather than rediscovering them. Google does not participate, so this is not a
 * substitute for the sitemap. It matters here because ChatGPT search leans on
 * Bing's index, which makes Bing the shortest path from "a chapter changed"
 * to "an assistant quotes the current version".
 *
 * Ownership is proved by serving the key as plain text at `/<key>.txt`. That
 * file is generated from this constant by `src/pages/[key].txt.ts` rather than
 * committed to `public/`: if the served file and the submitted key disagreed,
 * every submission would be rejected and nothing anywhere would fail.
 *
 * Not a secret. It is published at a known URL by design; all it proves is that
 * whoever submits URLs for this host can also write files to it.
 */
export const INDEXNOW_KEY = "504f28798996bd15c5f3e5e8910daa67";
