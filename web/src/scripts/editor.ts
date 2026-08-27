/** Lazily-loaded CodeMirror editor. Split out so it never lands in the initial bundle. */
import { EditorView, basicSetup } from "codemirror";
import { cpp } from "@codemirror/lang-cpp";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

export interface MountedEditor {
  getSource(): string;
  setSource(text: string): void;
}

/**
 * Every colour below is a `var(--code-*)` rather than a value, and that is the
 * whole switch. CodeMirror themes are CSS, so the browser resolves the token
 * the same way it resolves one in the stylesheet: the editor follows the
 * light and dark toggle with nothing here listening for it, and a mounted
 * editor repaints on a theme change without being told.
 *
 * The tokens are the two GitHub high-contrast themes the rest of the site is
 * highlighted with, so an editor looks like the block it replaced. This used
 * to be One Dark, which was both a different theme and a fixed dark one: on a
 * light page, pressing Edit turned the snippet black.
 */
const chrome = EditorView.theme({
  "&": {
    color: "var(--code-fg)",
    backgroundColor: "var(--code-bg)",
  },
  ".cm-content": { caretColor: "var(--code-fg)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--code-fg)" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
    { backgroundColor: "color-mix(in srgb, var(--code-literal) 28%, transparent)" },
  ".cm-activeLine": {
    backgroundColor: "color-mix(in srgb, var(--code-fg) 5%, transparent)",
  },
  ".cm-gutters": {
    color: "var(--code-comment)",
    backgroundColor: "var(--code-bg)",
    borderRight: "1px solid var(--border)",
  },
  ".cm-activeLineGutter": {
    backgroundColor: "color-mix(in srgb, var(--code-fg) 5%, transparent)",
  },
  ".cm-matchingBracket, &.cm-focused .cm-matchingBracket": {
    backgroundColor: "color-mix(in srgb, var(--code-literal) 24%, transparent)",
    color: "inherit",
  },
});

/*
 * Zig has no first-party CodeMirror grammar and this is the C++ one, so the
 * mapping is close rather than exact: it finds keywords, strings, numbers,
 * comments and call sites, and it does not know a builtin like `@sizeOf` from
 * an operator followed by a name. That is the same approximation the Edit
 * button has always shipped. What it must not do is disagree about colour with
 * the Shiki-rendered block it replaces, which is what these tags pin.
 */
const highlight = HighlightStyle.define([
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--code-comment)" },
  {
    tag: [
      t.keyword, t.controlKeyword, t.operatorKeyword, t.definitionKeyword,
      t.moduleKeyword, t.modifier, t.self, t.null, t.atom, t.bool,
      t.typeName, t.standard(t.typeName),
    ],
    color: "var(--code-keyword)",
  },
  { tag: [t.string, t.special(t.string), t.character, t.regexp], color: "var(--code-string)" },
  {
    tag: [t.number, t.integer, t.float, t.meta, t.macroName, t.processingInstruction],
    color: "var(--code-literal)",
  },
  {
    tag: [t.function(t.variableName), t.function(t.propertyName)],
    color: "var(--code-call)",
  },
  {
    tag: [t.variableName, t.propertyName, t.definition(t.variableName), t.className, t.labelName],
    color: "var(--code-name)",
  },
  {
    tag: [t.operator, t.punctuation, t.separator, t.bracket, t.derefOperator],
    color: "var(--code-fg)",
  },
  { tag: t.invalid, color: "var(--err)" },
]);

/**
 * Replace `host` with an editable view seeded from `source`.
 */
export function mountEditor(host: HTMLElement, source: string): MountedEditor {
  const container = document.createElement("div");
  container.className = "pg-editor";
  host.replaceWith(container);

  const view = new EditorView({
    doc: source,
    extensions: [basicSetup, cpp(), chrome, syntaxHighlighting(highlight)],
    parent: container,
  });

  return {
    getSource: () => view.state.doc.toString(),
    setSource: (text: string) =>
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
      }),
  };
}
