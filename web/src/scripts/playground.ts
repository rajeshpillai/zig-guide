/**
 * `<zig-playground>` — a runnable code block.
 *
 * Progressive enhancement: the element wraps a plain, already-syntax-highlighted
 * `<pre>` that renders fine with JS disabled. On upgrade it gains a Run button
 * that executes the CI-verified `.wasm`, and (lazily) an editor that recompiles
 * edited source in-browser.
 */
import { runWasm } from "./wasi-runner";
import type { ZigCompiler } from "./zig-compiler";

/** The in-browser compiler is multi-megabyte, so it loads only on demand. */
let compilerPromise: Promise<ZigCompiler> | null = null;
function loadCompiler(): Promise<ZigCompiler> {
  compilerPromise ??= import("./zig-compiler").then((m) => m.loadZigCompiler());
  return compilerPromise;
}

class ZigPlayground extends HTMLElement {
  #output!: HTMLPreElement;
  #status!: HTMLSpanElement;
  #runButton!: HTMLButtonElement;
  #editButton!: HTMLButtonElement;
  #revertButton!: HTMLButtonElement;
  #copyButton!: HTMLButtonElement;
  #editor: { getSource(): string; setSource(text: string): void } | null = null;
  /** The CI-verified source, captured before the editor can change it. */
  #original = "";

  /** Path to the prebuilt wasm, relative to the site root. */
  get #wasmUrl(): string {
    return `${import.meta.env.BASE_URL}wasm/${this.dataset.wasm}`;
  }

  get #source(): string {
    return this.#editor?.getSource() ?? this.querySelector("pre")?.textContent ?? "";
  }

  connectedCallback() {
    const toolbar = document.createElement("div");
    toolbar.className = "pg-toolbar";

    this.#runButton = document.createElement("button");
    this.#runButton.className = "pg-run";
    this.#runButton.textContent = "Run";
    this.#runButton.addEventListener("click", () => void this.#run());

    this.#editButton = document.createElement("button");
    this.#editButton.className = "pg-edit";
    this.#editButton.textContent = "Edit";
    this.#editButton.addEventListener("click", () => void this.#enableEditing());

    // Hidden until editing starts — there is nothing to revert before that.
    this.#revertButton = document.createElement("button");
    this.#revertButton.className = "pg-revert";
    this.#revertButton.textContent = "Revert";
    this.#revertButton.hidden = true;
    this.#revertButton.addEventListener("click", () => this.#revert());

    // Copies whatever the reader currently sees: the verified original, or
    // their edit if the editor is open.
    this.#copyButton = document.createElement("button");
    this.#copyButton.className = "pg-copy";
    this.#copyButton.textContent = "Copy";
    this.#copyButton.addEventListener("click", () => void this.#copy());

    this.#status = document.createElement("span");
    this.#status.className = "pg-status";

    // Capture the pristine source now, before any edit can mutate the DOM.
    this.#original = this.querySelector("pre")?.textContent ?? "";

    toolbar.append(
      this.#runButton,
      this.#editButton,
      this.#revertButton,
      this.#copyButton,
      this.#status,
    );

    this.#output = document.createElement("pre");
    this.#output.className = "pg-output";
    this.#output.hidden = true;

    this.prepend(toolbar);
    this.append(this.#output);
  }

  async #run() {
    this.#setBusy(true, "running…");
    try {
      // Compare against the original rather than merely checking whether the
      // editor is open, so reverting an edit goes back to the prebuilt,
      // CI-verified artifact instead of recompiling identical source.
      const edited = this.#source.trim() !== this.#original.trim();
      const url = edited
        ? await (await loadCompiler()).compile(this.#source, this.#kind())
        : this.#wasmUrl;

      const { output, exitCode, durationMs } = await runWasm(url);
      this.#show(output || "(no output)", exitCode === 0);
      this.#status.textContent = `exit ${exitCode} · ${durationMs.toFixed(0)}ms`;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.#show(message, false);
      this.#status.textContent = "failed";
      // Recompiling needs the in-browser compiler, which this deployment may
      // not carry. Offer a route that works rather than a dead end.
      if (message.includes("in-browser Zig compiler is not available")) {
        this.#offerExternalRun();
      }
    } finally {
      this.#setBusy(false);
    }
  }

  /**
   * Fallback when edited code cannot be recompiled here: copy the source and
   * hand the reader to a playground that can run it.
   */
  #offerExternalRun() {
    if (this.#output.querySelector(".pg-escape")) return;

    const escape = document.createElement("div");
    escape.className = "pg-escape";

    const copy = document.createElement("button");
    copy.textContent = "Copy source";
    copy.addEventListener("click", async () => {
      await navigator.clipboard.writeText(this.#source);
      copy.textContent = "Copied";
      setTimeout(() => (copy.textContent = "Copy source"), 1500);
    });

    const link = document.createElement("a");
    link.href = "https://playground.zigtools.org/";
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = "Open Zig playground ↗";

    const hint = document.createElement("span");
    hint.textContent = "Or press Revert to restore the verified original.";

    escape.append(copy, link, hint);
    this.#output.append(escape);
  }

  async #copy() {
    try {
      await navigator.clipboard.writeText(this.#source);
      this.#copyButton.textContent = "Copied";
    } catch {
      this.#copyButton.textContent = "Copy failed";
    }
    setTimeout(() => (this.#copyButton.textContent = "Copy"), 1500);
  }

  #kind(): "exe" | "test" {
    return this.dataset.kind === "test" ? "test" : "exe";
  }

  async #enableEditing() {
    if (this.#editor) return;
    this.#setBusy(true, "loading editor…");
    try {
      const { mountEditor } = await import("./editor");
      const pre = this.querySelector("pre:not(.pg-output)") as HTMLElement;
      this.#editor = mountEditor(pre, this.#source);
      this.#editButton.disabled = true;
      this.#editButton.textContent = "Editing";
      this.#revertButton.hidden = false;
      this.#status.textContent = "editable — Run will recompile";
    } finally {
      this.#setBusy(false);
    }
  }

  /**
   * Restore the CI-verified source. The snippet becomes pristine again, so
   * Run goes back to the prebuilt wasm instead of recompiling in-browser.
   */
  #revert() {
    if (!this.#editor) return;
    this.#editor.setSource(this.#original);
    this.#output.hidden = true;
    this.#status.textContent = "reverted to the verified original";
  }

  #setBusy(busy: boolean, message = "") {
    this.#runButton.disabled = busy;
    if (message) this.#status.textContent = message;
  }

  #show(text: string, ok: boolean) {
    this.#output.hidden = false;
    this.#output.textContent = text;
    this.#output.dataset.ok = String(ok);
  }
}

customElements.define("zig-playground", ZigPlayground);
