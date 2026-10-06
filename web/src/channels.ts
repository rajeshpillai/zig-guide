/**
 * The YouTube channels this site links to, and the shorts it features.
 *
 * Every surface that shows a short (the riddle break at the foot of a chapter
 * or post, the strip on the home page, the footer link) reads from here, so a
 * second channel is one more row in `CHANNELS` and one more key in the
 * snapshot.
 *
 * The list of shorts comes from two places, merged:
 *
 * - The channel's public RSS feed, read once per build. The nightly build is
 *   what picks up a new short, with nobody editing anything. The feed only
 *   carries the newest 15 uploads.
 * - `data/shorts.json`, a committed snapshot. It keeps the older shorts the
 *   feed no longer lists, and it is the whole list when the feed cannot be
 *   reached. A build never fails because YouTube was slow: a missing feed is
 *   a warning, and the site ships the snapshot. `npm run shorts` folds the
 *   current feed into the snapshot; run it now and then so a short does not
 *   drop out of both once 15 newer ones exist.
 *
 * Nothing from YouTube loads in the reader's browser. The cards are text and a
 * link, so there is no player, no thumbnail and no cookie until someone clicks
 * through, which is what the privacy page says.
 *
 * `SHORTS_FEED=off` skips the network and uses the snapshot alone, for an
 * offline build.
 */
import snapshot from "./data/shorts.json";

export interface Channel {
  /** Key in `data/shorts.json`. */
  key: string;
  name: string;
  handle: string;
  /** The `UC...` id, which the RSS feed is addressed by. */
  channelId: string;
  /**
   * A short whose raw title matches is a riddle, and its card says so. Every
   * other upload (the channel mixes in jokes) is featured as a "quick break".
   */
  riddle: RegExp;
}

export const CHANNELS: Channel[] = [
  {
    key: "riddlemasti",
    name: "Riddle Masti",
    handle: "@riddlemasti4u",
    channelId: "UCuCGG6Nk2KMWmVr9bPtLMfw",
    riddle: /riddle masti/i,
  },
];

export interface Short {
  id: string;
  /** The riddle as the card shows it: no emoji, no hashtags, no channel suffix. */
  title: string;
  url: string;
  kind: "riddle" | "teaser";
  channel: Channel;
}

export const channelUrl = (c: Channel) => `https://www.youtube.com/${c.handle}/shorts`;

/**
 * "🚆 Which way does the smoke go? | Riddle Masti #17 #Shorts" becomes
 * "Which way does the smoke go?". A title that is only the channel name
 * ("Riddle Masti - Nature") says nothing a card could show, so it comes back
 * empty and that short is left out.
 */
export function cleanTitle(raw: string): string {
  const title = raw
    .split(" | ")[0]
    .replace(/#\S+/g, "")
    .replace(/^[^\p{L}\p{N}]+/u, "")
    .replace(/[^\p{L}\p{N}?.!'")]+$/u, "")
    .trim();
  return /^riddle masti\b/i.test(title) ? "" : title;
}

interface Raw {
  id: string;
  title: string;
}

async function fetchFeed(channel: Channel): Promise<Raw[]> {
  if (process.env.SHORTS_FEED === "off") return [];
  const url = `https://www.youtube.com/feeds/videos.xml?channel_id=${channel.channelId}`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return parseFeed(await res.text());
  } catch (err) {
    console.warn(`[channels] ${channel.name} feed unavailable (${(err as Error).message}); using the snapshot`);
    return [];
  }
}

const decode = (s: string) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");

/** Entries in feed order, which is newest first. */
export function parseFeed(xml: string): Raw[] {
  return [...xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)].flatMap(([, entry]) => {
    const id = entry.match(/<yt:videoId>([^<]+)<\/yt:videoId>/)?.[1];
    const title = entry.match(/<title>([^<]*)<\/title>/)?.[1];
    return id && title ? [{ id, title: decode(title) }] : [];
  });
}

/** Feed first, then the snapshot, one entry per id. */
export function merge(feed: Raw[], saved: Raw[]): Raw[] {
  const seen = new Set<string>();
  return [...feed, ...saved].filter((r) => !seen.has(r.id) && seen.add(r.id));
}

let cached: Promise<Short[]> | undefined;

/** Every featured short, newest first, across all channels. Fetched once per build. */
export function shorts(): Promise<Short[]> {
  cached ??= (async () => {
    const lists = await Promise.all(
      CHANNELS.map(async (channel) => {
        const saved = (snapshot as Record<string, Raw[]>)[channel.key] ?? [];
        return merge(await fetchFeed(channel), saved)
          .map((r) => ({
            id: r.id,
            title: cleanTitle(r.title),
            url: `https://www.youtube.com/shorts/${r.id}`,
            kind: channel.riddle.test(r.title) ? ("riddle" as const) : ("teaser" as const),
            channel,
          }))
          .filter((s) => s.title);
      }),
    );
    // Interleave the channels so a second one is not buried under the first.
    const out: Short[] = [];
    for (let i = 0; lists.some((l) => i < l.length); i++) {
      for (const l of lists) if (i < l.length) out.push(l[i]);
    }
    return out;
  })();
  return cached;
}

/**
 * The short a page shows in its riddle break. Picked from the page's own path,
 * so a page keeps its riddle from one build to the next until the list
 * changes, and neighbouring pages usually show different ones.
 */
export async function shortFor(path: string): Promise<Short | undefined> {
  const list = await shorts();
  if (list.length === 0) return undefined;
  let h = 2166136261;
  for (const ch of path) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
  return list[(h >>> 0) % list.length];
}

/** What a card calls each kind of short. */
export const LABELS = {
  riddle: { kicker: "Riddle break", play: "▶ Play the riddle" },
  teaser: { kicker: "Quick break", play: "▶ Play" },
} as const;
