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
 *
 * Finding the declaration is `src/source-quote.ts`, shared with the component
 * that quotes out of `snippets/`.
 */
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { extractDecl } from "./source-quote";

// Anchored to the Astro project root (`web/`) for the same reason
// `snippets.ts` is: `import.meta.url` points into the bundle once a component
// importing this has been compiled.
const projectRoot = resolve(process.cwd(), "../examples/lane-dodger");

/** A whole file, or one declaration out of it. */
export async function gameSource(
  file: string,
  decl?: string,
  fieldsOnly = false,
): Promise<string> {
  if (file.includes("..")) throw new Error(`gameSource: refusing path "${file}"`);

  const path = resolve(projectRoot, file);
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch {
    throw new Error(`gameSource: no such file examples/lane-dodger/${file}`);
  }

  if (!decl) return text.trimEnd();
  return extractDecl(text, decl, `examples/lane-dodger/${file}`, fieldsOnly, "gameSource");
}
