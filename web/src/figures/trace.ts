/**
 * Shared parts of the stepped figures: reading a snippet's verified output,
 * and the theme that ties tinyfly's markup to the site's colour tokens.
 *
 * A figure is never drawn by hand. Each one is built during `astro build`
 * from the `.expected` file that `zig build verify` diffs the snippet against,
 * so the numbers in the picture are the numbers CI saw. A hand-drawn diagram
 * would be exactly the unverified second code path this repo forbids, in a
 * picture's clothes. When a snippet's output changes shape, the parser here
 * throws and the build fails, rather than a figure quietly showing old data.
 */
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import type { Theme } from "@algorisys/tinyfly/teach";
import { findSnippet } from "../snippets";

/** The verified stdout of a snippet, from the file CI diffs it against. */
export async function expectedOutput(snippet: string): Promise<string> {
  const entry = await findSnippet(snippet);
  const path = resolve(process.cwd(), "..", entry.source.replace(/\.zig$/, ".expected"));
  return readFile(path, "utf8");
}

/**
 * The lines of one block of the output: the line that starts with `heading`
 * (after indentation) up to the next blank line, heading excluded.
 */
export function block(output: string, heading: string, figure: string): string[] {
  const lines = output.split("\n");
  const at = lines.findIndex((line) => line.trim().startsWith(heading));
  if (at === -1) {
    throw new Error(`${figure}: the snippet output has no block starting "${heading}". Did the trace change?`);
  }
  const body: string[] = [];
  for (const line of lines.slice(at + 1)) {
    if (line.trim() === "") break;
    body.push(line);
  }
  return body;
}

/** Throw with the figure's name when a parsed trace breaks its own rules. */
export function check(condition: unknown, figure: string, message: string): asserts condition {
  if (!condition) throw new Error(`${figure}: ${message}`);
}

/**
 * Every colour is a site token, so a figure follows the palette and the light
 * or dark mode the reader chose, with nothing listening for the change.
 * tinyfly writes theme colours as SVG presentation attributes; `tokensToStyle`
 * below moves them into `style`, where every browser resolves `var()`.
 */
export const THEME: Partial<Theme> = {
  stroke: "var(--muted)",
  fill: "var(--surface)",
  text: "var(--text)",
  accent: "var(--accent)",
  // `cells` fills an empty cell with `muted`, so it is a surface, not a text grey.
  muted: "var(--sunken)",
};

/**
 * Move `fill="var(--x)"` and `stroke="var(--x)"` attributes into the element's
 * `style`. Chromium resolves `var()` in a presentation attribute, but the SVG
 * specification does not promise it, and a figure that turned black in one
 * browser would pass every gate here, which only runs Chromium.
 */
export function tokensToStyle(markup: string): string {
  return markup.replace(/<([a-zA-Z]+)((?:\s+[^\s=>]+="[^"]*")*)\s*(\/?)>/g, (whole, tag: string, attrs: string, close: string) => {
    const moved: string[] = [];
    let rest = attrs.replace(/\s+(fill|stroke)="(var\([^"]*\))"/g, (_m, name: string, value: string) => {
      moved.push(`${name}:${value}`);
      return "";
    });
    if (moved.length === 0) return whole;
    const style = rest.match(/\s+style="([^"]*)"/);
    if (style) {
      const merged = `${style[1].replace(/;?$/, ";")}${moved.join(";")}`;
      rest = rest.replace(style[0], ` style="${merged}"`);
    } else {
      rest += ` style="${moved.join(";")}"`;
    }
    return `<${tag}${rest}${close ? " /" : ""}>`;
  });
}

/** A piece of plain SVG for `figure()`, for the parts no primitive draws. */
export function svgPiece(svg: string): { svg: string } {
  return { svg };
}

/** Escape text for an SVG `<text>` element. */
export function esc(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
