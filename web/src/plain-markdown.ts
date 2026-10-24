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
import { findSnippet, snippetCompileError, snippetSource } from "./snippets";
import { buildFigure } from "./figures";
import { exampleSource, gameSource } from "./game-source";
import { extractDecl } from "./source-quote";

const base = import.meta.env.BASE_URL;



function attr(tag: string, name: string): string | undefined {
  return tag.match(new RegExp(`${name}=\\{?"([^"]*)"`))?.[1];
}

/** A bare boolean attribute such as `fields`, or `fields={true}`. */
function flag(tag: string, name: string): boolean {
  return new RegExp(`(^|\\s)${name}(\\s|$|=\\{true\\})`).test(tag);
}

function required(tag: string, name: string, component: string): string {
  const value = attr(tag, name);
  if (!value) throw new Error(`plain-markdown: <${component}> without ${name}="…"`);
  return value;
}

/** A quoted piece of source, with the path it came from under it. */
function quote(code: string, lang: string, path: string, decl?: string, fields = false): string {
  const what = decl ? `\`${decl}\`${fields ? " (fields only)" : ""} from \`${path}\`` : `\`${path}\``;
  return `\`\`\`${lang}\n${code}\n\`\`\`\n\n*Quoted from the source: ${what}.*`;
}

/** An interactive embed has no text form. Say what it is and where it runs. */
function interactive(what: string) {
  return async (tag: string) => {
    const caption = attr(tag, "caption");
    return `*Interactive: ${what}.${caption ? ` ${caption}` : ""} It runs on the web page of this chapter.*`;
  };
}

/**
 * Each component a chapter can use, and its text form. A component missing
 * from this table would reach the Markdown as a raw tag, which is what
 * happened to every source quote until 2026-10-25: 287 of them, each a tag
 * name where the code should have been. `chapterBody` now throws on any
 * component tag that is left, so a new component needs an entry here.
 */
const COMPONENTS: Record<string, (tag: string) => Promise<string>> = {
  async Playground(tag) {
    const name = required(tag, "name", "Playground");
    const snippet = await findSnippet(name);
    const source = await snippetSource(snippet);
    // The note explains why a snippet cannot run in the browser sandbox. It is
    // on the page, so it belongs here: without it the code reads as if it were
    // simply not offered, rather than as one CI compiles and runs natively.
    const note = snippet.runnable
      ? `Runnable: compiled to WebAssembly and executed by CI against Zig master.`
      : (attr(tag, "note") ?? "Compiled by CI, but not runnable in the browser sandbox.");
    // A compile-fails snippet's lesson is the message, so the twin carries it.
    const error = snippet.compileFails
      ? `\n\nThe compiler says:\n\n\`\`\`\n${await snippetCompileError(snippet)}\n\`\`\``
      : "";
    return `\`\`\`zig\n${source}\n\`\`\`${error}\n\n*${note} (\`${name}\`)*`;
  },

  // A stepped figure has no text form, but its description and caption do:
  // the reader of this copy learns that the page has one and what it shows.
  async TraceFigure(tag) {
    const fig = await buildFigure(required(tag, "name", "TraceFigure"));
    return `*Figure: ${fig.alt} ${fig.caption}*`;
  },

  async SnippetSource(tag) {
    const entry = await findSnippet(required(tag, "name", "SnippetSource"));
    const text = await snippetSource(entry);
    const decl = attr(tag, "decl");
    const fields = flag(tag, "fields");
    const code = decl ? extractDecl(text, decl, entry.source, fields, "SnippetSource") : text;
    return quote(code, "zig", entry.source, decl, fields);
  },

  async GameSource(tag) {
    const file = required(tag, "file", "GameSource");
    const decl = attr(tag, "decl");
    const fields = flag(tag, "fields");
    return quote(await gameSource(file, decl, fields), attr(tag, "lang") ?? "zig", `examples/lane-dodger/${file}`, decl, fields);
  },

  async PaintSource(tag) {
    const file = required(tag, "file", "PaintSource");
    const decl = attr(tag, "decl");
    const fields = flag(tag, "fields");
    return quote(await exampleSource("paint", file, decl, fields), attr(tag, "lang") ?? "zig", `examples/paint/${file}`, decl, fields);
  },

  // The file list is a JavaScript array literal in the chapter. It is the
  // chapter's own data, written by hand, so it is read as a literal here.
  async GameFiles(tag) {
    const literal = tag.match(/files=\{([\s\S]*)\}\s*$/)?.[1];
    if (!literal) throw new Error("plain-markdown: <GameFiles> without files={[…]}");
    const files = new Function(`return (${literal});`)() as Array<{ path: string; what: string; chapter?: string; chapterTitle?: string }>;
    return files
      .map((f) => `- \`examples/lane-dodger/${f.path}\`: ${f.what}${f.chapter ? ` [${f.chapterTitle ?? "Explained here"}](${f.chapter}).` : ""}`)
      .join("\n");
  },

  LaneDodger: interactive("the game, compiled to WebAssembly"),
  PaintStudio: interactive("the paint program, compiled to WebAssembly"),
  WatercolorLab: interactive("the watercolour simulation, compiled to WebAssembly"),
};

const COMPONENT = new RegExp(`<(${Object.keys(COMPONENTS).join("|")})\\b([\\s\\S]*?)\\/>`, "g");

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
  for (const [, component, tag] of md.matchAll(COMPONENT)) {
    blocks.push(await COMPONENTS[component](tag));
  }
  let at = 0;
  md = md.replace(COMPONENT, () => blocks[at++]);

  // A component tag left at the start of a line has no text form yet. Outside
  // a code fence, that is a tag name where content should be: fail the build
  // rather than publish it.
  let fenced = false;
  for (const line of md.split("\n")) {
    if (line.trimStart().startsWith("```")) fenced = !fenced;
    const left = !fenced && line.match(/^\s*<([A-Z][A-Za-z]+)\b/);
    if (left) {
      throw new Error(`plain-markdown: ${entry.id} uses <${left[1]}>, which has no text form. Add it to COMPONENTS.`);
    }
  }

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
