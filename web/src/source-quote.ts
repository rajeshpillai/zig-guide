/**
 * Cutting one declaration out of a Zig file, for the components that quote
 * source into a chapter.
 *
 * Two of them do it now. `GameSource` reads out of `examples/lane-dodger/`,
 * which has its own build and is not a snippet. `SnippetSource` reads a
 * snippet the manifest already lists, so a chapter can walk through a program
 * one function at a time and still show the whole thing under a Run button.
 * The rule both enforce is the same one: a chapter quotes nothing by hand, so
 * a name that no longer exists fails the build instead of leaving a paragraph
 * describing code that has been deleted.
 *
 * The extraction lives here rather than in either component because a copy of
 * it would drift the moment one side learned about a new declaration shape,
 * and the failure would be a chapter quietly quoting the wrong lines.
 */

/**
 * A declaration, found by name and cut at the closing brace sitting at the
 * same indentation. That holds because everything quoted here has been through
 * `zig fmt`. Any `///` doc comment directly above comes with it: in this
 * codebase the comment above a declaration is usually the reason the
 * declaration is worth quoting.
 *
 * `where` is the file as a reader would name it, and appears in the error.
 * `who` is the component asking, so a failed build says which one to look at.
 */
export function extractDecl(
  text: string,
  decl: string,
  where: string,
  fieldsOnly = false,
  who = "sourceQuote",
): string {
  const lines = text.split("\n");
  const escaped = decl.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // A declaration by name, or a test by its title. Tests are worth quoting and
  // are named with a string rather than an identifier, so both spellings
  // resolve here rather than being pasted into a chapter by hand.
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
        if (!fieldsOnly) return lines.slice(start, j + 1).join("\n");

        // A struct that carries its own methods is mostly methods. `World` is
        // 309 lines, and the chapters quote the interesting ones separately, so
        // showing the whole thing is a wall of code the reader has already been
        // given. Cut at the first method instead. The lines are still read off
        // disk; only the ellipsis is added, and the caption says it is an
        // excerpt.
        let end = j;
        for (let k = i + 1; k < j; k++) {
          if (/^\s+(?:pub\s+)?fn\s/.test(lines[k])) {
            end = k;
            break;
          }
        }
        if (end === j) return lines.slice(start, j + 1).join("\n");
        const body = lines.slice(start, end).join("\n").trimEnd();
        return `${body}\n\n${indent}    // ...\n${closer};`;
      }
    }
    throw new Error(
      `${who}: "${decl}" in ${where} has no closing brace at its own indent. ` +
        `Has the file been through zig fmt?`,
    );
  }

  throw new Error(`${who}: no declaration named "${decl}" in ${where}`);
}
