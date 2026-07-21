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
  #editor: { getSource(): string } | null = null;

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

    this.#status = document.createElement("span");
    this.#status.className = "pg-status";

    toolbar.append(this.#runButton, this.#editButton, this.#status);

    this.#output = document.createElement("pre");
    this.#output.className = "pg-output";
    this.#output.hidden = true;

    this.prepend(toolbar);
    this.append(this.#output);
  }

  async #run() {
    this.#setBusy(true, "running…");
    try {
      // An edited snippet must be recompiled; a pristine one already has a
      // CI-verified artifact sitting on the CDN.
      const url = this.#editor
        ? await (await loadCompiler()).compile(this.#source, this.#kind())
        : this.#wasmUrl;

      const { output, exitCode, durationMs } = await runWasm(url);
      this.#show(output || "(no output)", exitCode === 0);
      this.#status.textContent = `exit ${exitCode} · ${durationMs.toFixed(0)}ms`;
    } catch (err) {
      this.#show(err instanceof Error ? err.message : String(err), false);
      this.#status.textContent = "failed";
    } finally {
      this.#setBusy(false);
    }
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
      this.#status.textContent = "editable — Run will recompile";
    } finally {
      this.#setBusy(false);
    }
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
