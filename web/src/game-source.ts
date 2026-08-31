/**
 * Source quoted from `examples/lane-dodger/`, read at build time.
 *
 * The guide's rule is that the code on a page is the code CI compiled. For a
 * `<Playground>` that is enforced by the manifest `zig build` writes. The game
 * is not a snippet: it is a separate project with its own build, its own tests
 * and, on the web, its own toolchain. So the enforcement here is simpler and
 * has the same effect. The chapters quote nothing by hand; they name a file and
 * a declaration, this reads it off disk, and a name that no longer exists is a
 * failed build rather than a paragraph describing code that has been deleted.
 */
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

// Anchored to the Astro project root (`web/`) for the same reason
// `snippets.ts` is: `import.meta.url` points into the bundle once a component
// importing this has been compiled.
const projectRoot = resolve(process.cwd(), "../examples/lane-dodger");

/**
 * A whole file, or one declaration out of it.
 *
 * Declarations are found by name and cut at the closing brace sitting at the
 * same indentation, which holds because everything here has been through
 * `zig fmt`. Any `///` doc comment directly above comes with it: in this
 * codebase the comment above a declaration is usually the reason the
 * declaration is worth quoting.
 */
export async function gameSource(file: string, decl?: string): Promise<string> {
  if (file.includes("..")) throw new Error(`gameSource: refusing path "${file}"`);

  const path = resolve(projectRoot, file);
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch {
    throw new Error(`gameSource: no such file examples/lane-dodger/${file}`);
  }

  if (!decl) return text.trimEnd();
  return extract(text, decl, file);
}

function extract(text: string, decl: string, file: string): string {
  const lines = text.split("\n");
  const escaped = decl.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // A declaration by name, or a test by its title. Tests are the most worth
  // quoting in this project and are named with a string rather than an
  // identifier, so both spellings resolve here rather than being pasted into a
  // chapter by hand.
  const opener = new RegExp(
    `^(\\s*)(?:(?:pub\\s+)?(?:const|var|fn)\\s+${escaped}\\b|test\\s+"${escaped}")`,
  );

  for (let i = 0; i < lines.length; i++) {
    const match = opener.exec(lines[i]);
    if (!match) continue;

    const indent = match[1];

    // Take any doc comment written directly above it.
    let start = i;
    while (start > 0 && lines[start - 1].trim().startsWith("///")) start--;

    // A declaration with no body ends on its own line.
    if (!lines[i].includes("{")) return lines.slice(start, i + 1).join("\n");

    const closer = `${indent}}`;
    for (let j = i + 1; j < lines.length; j++) {
      if (lines[j] === closer || lines[j].startsWith(`${closer};`)) {
        return lines.slice(start, j + 1).join("\n");
      }
    }
    throw new Error(
      `gameSource: "${decl}" in ${file} has no closing brace at its own indent. ` +
        `Has the file been through zig fmt?`,
    );
  }

  throw new Error(`gameSource: no declaration named "${decl}" in examples/lane-dodger/${file}`);
}
