/** Lazily-loaded CodeMirror editor. Split out so it never lands in the initial bundle. */
import { EditorView, basicSetup } from "codemirror";
import { cpp } from "@codemirror/lang-cpp";
import { oneDark } from "@codemirror/theme-one-dark";

export interface MountedEditor {
  getSource(): string;
}

/**
 * Replace `host` with an editable view seeded from `source`.
 *
 * Zig has no first-party CodeMirror mode; the C++ mode is a close enough
 * approximation for keywords, strings, numbers, and comments.
 */
export function mountEditor(host: HTMLElement, source: string): MountedEditor {
  const container = document.createElement("div");
  container.className = "pg-editor";
  host.replaceWith(container);

  const view = new EditorView({
    doc: source,
    extensions: [basicSetup, cpp(), oneDark],
    parent: container,
  });

  return {
    getSource: () => view.state.doc.toString(),
  };
}
