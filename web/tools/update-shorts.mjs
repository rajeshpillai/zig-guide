// Folds each channel's current RSS feed into src/data/shorts.json.
//
// The build reads the feed itself, so this is not needed for a new short to
// appear. It is needed so an older short stays listed after 15 newer uploads
// push it out of the feed. Run it now and then and commit the result:
//
//   npm run shorts
//
// The channel ids are read out of src/channels.ts so they live in one place.

import { readFileSync, writeFileSync } from "node:fs";

const root = new URL("../src/", import.meta.url);
const source = readFileSync(new URL("channels.ts", root), "utf8");
const channels = [...source.matchAll(/key:\s*"([^"]+)"[\s\S]*?channelId:\s*"([^"]+)"/g)].map(
  ([, key, channelId]) => ({ key, channelId }),
);
if (channels.length === 0) throw new Error("no channels found in src/channels.ts");

const file = new URL("data/shorts.json", root);
const snapshot = JSON.parse(readFileSync(file, "utf8"));

const decode = (s) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");

for (const { key, channelId } of channels) {
  const res = await fetch(`https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`);
  if (!res.ok) throw new Error(`${key}: HTTP ${res.status}`);
  const xml = await res.text();
  const feed = [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].flatMap(([, e]) => {
    const id = e.match(/<yt:videoId>([^<]+)<\/yt:videoId>/)?.[1];
    const title = e.match(/<title>([^<]*)<\/title>/)?.[1];
    return id && title ? [{ id, title: decode(title) }] : [];
  });
  const saved = snapshot[key] ?? [];
  const seen = new Set();
  snapshot[key] = [...feed, ...saved].filter((r) => !seen.has(r.id) && seen.add(r.id));
  console.log(`${key}: ${snapshot[key].length - saved.length} new, ${snapshot[key].length} total`);
}

writeFileSync(file, JSON.stringify(snapshot, null, 2) + "\n");
