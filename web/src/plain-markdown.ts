/**
 * A chapter as plain Markdown, for readers that are not browsers.
 *
 * Three surfaces want this: `/llms.txt`, `/llms-full.txt`, and the `.md` twin
 * of every chapter URL. What they want is the prose *with the code in it*: an
 * agent that fetches a page about optionals and gets `<Playground name="..."/>`
 * has been handed a component name instead of the program, which is the one
 * part of this site worth quoting. So the component is expanded to a fenced
 * block holding exactly the source the playground shows.
 *
 * Deliberately a string transform rather than a second render pass. The MDX is
 * already Markdown apart from the imports and the one component, and running it
 * through a real pipeline would mean maintaining a second content path, the
 * thing this repo exists to avoid.
 */
import type { Doc } from "./nav";
import { findSnippet, snippetSource } from "./snippets";

const base = import.meta.env.BASE_URL;

/** `<Playground ... />`, on one line or spread over several. */
const PLAYGROUND = /<Playground\b([\s\S]*?)\/>/g;

function attr(tag: string, name: string): string | undefined {
  return tag.match(new RegExp(`${name}=\\{?"([^"]*)"`))?.[1];
}

/**
 * Root-absolute content links carry no base path (chapter authors write
 * `/learn/language-basics/slices/`), the same reason `rehype-base-links` exists
 * for the HTML. Applying it here too keeps the Markdown correct on a project
 * site; `origin` additionally makes the links absolute, which is what a fetched
 * `.md` or a concatenated `llms-full.txt` needs, since neither has a page URL
 * to resolve against.
 */
function absolutise(md: string, origin?: string): string {
  const prefix = base.replace(/\/+$/, "");
  return md.replace(/\]\((\/[^)\s]*)\)/g, (whole, href: string) => {
    if (href.startsWith("//")) return whole;
    const path = href === prefix || href.startsWith(`${prefix}/`) ? href : prefix + href;
    return `](${origin ? origin.replace(/\/$/, "") + path : path})`;
  });
}

/**
 * The chapter body: MDX imports removed, every playground replaced by its
 * verified source. Does not include the title; callers place their own heading
 * because the level differs between a standalone `.md` and a concatenated file.
 */
export async function chapterBody(entry: Doc, origin?: string): Promise<string> {
  let md = (entry.body ?? "").replace(/^import\s+.*$/gm, "");

  // Collected first because the replacement is async and `String.replace` is
  // not. Order is preserved, so the second pass can consume them in sequence.
  const blocks: string[] = [];
  for (const [, tag] of md.matchAll(PLAYGROUND)) {
    const name = attr(tag, "name");
    if (!name) {
      blocks.push("");
      continue;
    }
    const snippet = await findSnippet(name);
    const source = await snippetSource(snippet);
    // The note explains why a snippet cannot run in the browser sandbox. It is
    // on the page, so it belongs here: without it the code reads as if it were
    // simply not offered, rather than as one CI compiles and runs natively.
    const note = snippet.runnable
      ? `Runnable: compiled to WebAssembly and executed by CI against Zig master.`
      : (attr(tag, "note") ?? "Compiled by CI, but not runnable in the browser sandbox.");
    blocks.push(`\`\`\`zig\n${source}\n\`\`\`\n\n*${note} (\`${name}\`)*`);
  }

  let at = 0;
  md = md.replace(PLAYGROUND, () => blocks[at++]);

  return absolutise(md, origin).replace(/\n{3,}/g, "\n\n").trim();
}

/** A chapter as a standalone Markdown document, title and all. */
export async function chapterMarkdown(entry: Doc, origin?: string): Promise<string> {
  const lines = [`# ${entry.data.title}`];
  if (entry.data.description) lines.push("", `> ${entry.data.description}`);
  // The blank line is load-bearing: a blockquote followed immediately by a
  // paragraph is a lazy continuation, so the chapter's opening lines would be
  // pulled inside the quote by every Markdown parser that reads this.
  return `${lines.join("\n")}\n\n${await chapterBody(entry, origin)}\n`;
}
