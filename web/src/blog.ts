/**
 * The blog's posts, in the one order every surface shows them: newest first.
 *
 * `/blog/`, each post page, `/blog/rss.xml` and the sitemap all read this, so
 * a post cannot be listed in one place and missing from another.
 */
import { getCollection, type CollectionEntry } from "astro:content";

export type Post = CollectionEntry<"blog">;

export const blogHref = `${import.meta.env.BASE_URL}blog/`;

export const postHref = (post: Post) => `${blogHref}${post.id}/`;

export async function posts(): Promise<Post[]> {
  const all = await getCollection("blog");
  // By instant, newest first. Same instant (two posts dated by day only): title
  // order, so they do not swap places from one build to the next.
  return all.sort(
    (a, b) => instant(b) - instant(a) || a.data.title.localeCompare(b.data.title),
  );
}

/** The day the post went out, as written: `YYYY-MM-DD`. */
export const postDay = (post: Post) => post.data.date.slice(0, 10);

/**
 * The moment the post went out, in milliseconds. A post dated by day alone
 * counts as noon UTC on that day, which keeps it on the same calendar day for
 * every reader and sorts it into the middle of the day rather than either end.
 */
export function instant(post: Post): number {
  const { date } = post.data;
  return Date.parse(date.length === 10 ? `${date}T12:00:00Z` : date);
}

/**
 * `3 Oct 2026`. By hand rather than toLocaleDateString, whose "en-GB" short
 * month is "Sept" and whose output depends on the ICU data Node ships. The
 * chapter pages format their date the same way.
 */
export function readableDate(iso: string): string {
  const [y, m, d] = iso.split("-");
  const month = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(" ")[Number(m) - 1];
  return `${Number(d)} ${month} ${y}`;
}

/** True when the post has code that is gated nightly, through a snippet. */
export const hasCheckedCode = (post: Post) => /<(Playground|SnippetSource)\b/.test(post.body ?? "");

/** True when the post has a fenced block that nothing re-checks. */
export const hasPlainCode = (post: Post) => /^```/m.test(post.body ?? "");
