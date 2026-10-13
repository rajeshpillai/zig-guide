/**
 * The paint studio: pointer events in, the engine's pixels out.
 *
 * Everything that decides what a pixel becomes lives in the Zig engine
 * (`examples/paint/`). This file only turns browser events into the engine's
 * calls and copies the rectangle the engine says changed onto the canvas. It
 * is the same split as the engine's tests, which call the same functions with
 * points of their own and no browser at all.
 */

interface PaintExports {
  memory: WebAssembly.Memory;
  paint_init(width: number, height: number): number;
  paint_display(): number;
  paint_set_brush(
    radius: number, hardness: number, flow: number, opacity: number, spacing: number,
    follow: number, pressure: number, jitter: number, scatter: number, aspect: number,
    angle: number, followDirection: number, r: number, g: number, b: number, seed: number,
  ): void;
  paint_set_tool(tool: number): void;
  paint_begin(x: number, y: number, pressure: number): void;
  paint_move(x: number, y: number, pressure: number): void;
  paint_end(): void;
  paint_cancel(): void;
  paint_fill(x: number, y: number): number;
  paint_undo(): number;
  paint_redo(): number;
  paint_can_undo(): number;
  paint_can_redo(): number;
  paint_history_ok(): number;
  paint_set_layer(index: number): number;
  paint_render(): number;
  paint_changed(edge: number): number;
  paint_hash(): number;
  paint_export_png(): number;
  paint_png(): number;
  paint_self_test(): number;
}

/** A named set of brush settings (lessons 62 and 71). Size and opacity come from the sliders. */
interface Preset {
  hardness: number;
  flow: number;
  spacing: number;
  follow: number;
  pressure: number;
  jitter: number;
  scatter: number;
  aspect: number;
  angle: number;
  followDirection: boolean;
}

const PRESETS: Record<string, Preset> = {
  pencil: { hardness: 0.9, flow: 0.9, spacing: 0.15, follow: 0.6, pressure: 0.6, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false },
  ink: { hardness: 0.95, flow: 1, spacing: 0.1, follow: 0.35, pressure: 1, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false },
  soft: { hardness: 0.1, flow: 0.12, spacing: 0.2, follow: 0.5, pressure: 0.3, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false },
  airbrush: { hardness: 0, flow: 0.04, spacing: 0.1, follow: 0.8, pressure: 0, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false },
  calligraphy: { hardness: 0.95, flow: 1, spacing: 0.08, follow: 0.4, pressure: 0.4, jitter: 0, scatter: 0, aspect: 0.2, angle: -45, followDirection: false },
  ribbon: { hardness: 0.8, flow: 1, spacing: 0.08, follow: 0.4, pressure: 0.5, jitter: 0, scatter: 0, aspect: 0.25, angle: 90, followDirection: true },
  spray: { hardness: 0.6, flow: 0.7, spacing: 1.2, follow: 1, pressure: 0, jitter: 0.6, scatter: 2.5, aspect: 1, angle: 0, followDirection: false },
};

const TOOLS = { brush: 0, eraser: 1 } as const;

export async function startPaint(root: HTMLElement, wasmUrl: string): Promise<void> {
  const canvas = root.querySelector<HTMLCanvasElement>(".paint-canvas")!;
  const status = root.querySelector<HTMLElement>(".paint-status")!;
  const ctx = canvas.getContext("2d")!;
  const width = canvas.width;
  const height = canvas.height;

  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`could not fetch the engine (HTTP ${response.status})`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  const e = instance.exports as unknown as PaintExports;
  if (!e.paint_init(width, height)) throw new Error("the engine could not allocate a document");

  const control = <T extends HTMLElement>(name: string) =>
    root.querySelector<T>(`[data-control="${name}"]`)!;
  const preset = control<HTMLSelectElement>("preset");
  const size = control<HTMLInputElement>("size");
  const opacity = control<HTMLInputElement>("opacity");
  const color = control<HTMLInputElement>("color");
  const layer = control<HTMLSelectElement>("layer");
  const undo = control<HTMLButtonElement>("undo");
  const redo = control<HTMLButtonElement>("redo");
  const save = control<HTMLButtonElement>("save");
  const toolInputs = root.querySelectorAll<HTMLInputElement>('input[name="paint-tool"]');

  let seed = 1;
  const tool = () => root.querySelector<HTMLInputElement>('input[name="paint-tool"]:checked')?.value ?? "brush";

  /** Send every setting to the engine. The engine copies the brush when a stroke starts, so a change mid-stroke waits for the next one. */
  function applyBrush() {
    const p = PRESETS[preset.value] ?? PRESETS.pencil;
    const hex = color.value;
    e.paint_set_brush(
      Number(size.value), p.hardness, p.flow, Number(opacity.value) / 100, p.spacing,
      p.follow, p.pressure, p.jitter, p.scatter, p.aspect, p.angle, p.followDirection ? 1 : 0,
      parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16),
      seed,
    );
    e.paint_set_tool(tool() === "eraser" ? TOOLS.eraser : TOOLS.brush);
  }

  // ---- drawing --------------------------------------------------------------

  let frame = 0;
  /** Copy the rectangle the engine changed onto the canvas, at most once a frame. */
  function scheduleDraw() {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      draw();
    });
  }

  function draw() {
    if (!e.paint_render()) return;
    const x0 = e.paint_changed(0);
    const y0 = e.paint_changed(1);
    const w = e.paint_changed(2) - x0;
    const h = e.paint_changed(3) - y0;
    // A fresh view every time: the engine's memory can grow, and growing it
    // replaces the buffer any older view was looking at.
    const all = new Uint8ClampedArray(e.memory.buffer, e.paint_display(), width * height * 4);
    const image = new ImageData(w, h);
    for (let row = 0; row < h; row++) {
      const from = ((y0 + row) * width + x0) * 4;
      image.data.set(all.subarray(from, from + w * 4), row * w * 4);
    }
    ctx.putImageData(image, x0, y0);
    updateButtons();
  }

  function updateButtons() {
    undo.disabled = !e.paint_can_undo();
    redo.disabled = !e.paint_can_redo();
    status.textContent = e.paint_history_ok()
      ? ""
      : "The last action was too large to keep in the undo history. It cannot be undone.";
  }

  // ---- pointer input --------------------------------------------------------

  /** Canvas pixels, whatever size CSS has made the canvas on screen. */
  function toDocument(ev: PointerEvent): [number, number] {
    const box = canvas.getBoundingClientRect();
    return [
      ((ev.clientX - box.left) * width) / box.width,
      ((ev.clientY - box.top) * height) / box.height,
    ];
  }

  /** A mouse has no pressure, and browsers report 0.5 while a button is down. A pen reports the real value. */
  const pressureOf = (ev: PointerEvent) => (ev.pointerType === "pen" ? ev.pressure : 0.5);

  let drawing: number | null = null;

  canvas.addEventListener("pointerdown", (ev) => {
    if (ev.button !== 0 || drawing !== null) return;
    ev.preventDefault();
    // Focus, so Ctrl+Z after a stroke reaches the studio and not the page.
    canvas.focus({ preventScroll: true });
    const [x, y] = toDocument(ev);
    if (tool() === "fill") {
      if (x >= 0 && y >= 0 && x < width && y < height) e.paint_fill(Math.floor(x), Math.floor(y));
      scheduleDraw();
      return;
    }
    applyBrush();
    canvas.setPointerCapture(ev.pointerId);
    drawing = ev.pointerId;
    e.paint_begin(x, y, pressureOf(ev));
    scheduleDraw();
  });

  canvas.addEventListener("pointermove", (ev) => {
    if (ev.pointerId !== drawing) return;
    // The browser may merge several samples into one event between frames.
    // Each one is a point on the path, so all of them go to the engine.
    const samples = ev.getCoalescedEvents?.() ?? [];
    for (const s of samples.length > 0 ? samples : [ev]) {
      const [x, y] = toDocument(s);
      e.paint_move(x, y, pressureOf(s));
    }
    scheduleDraw();
  });

  function finish(ev: PointerEvent) {
    if (ev.pointerId !== drawing) return;
    drawing = null;
    e.paint_end();
    seed++; // the next stroke scatters differently
    scheduleDraw();
  }

  /** The stroke was interrupted, not finished: drop it rather than commit half of it (lesson 40). */
  function abandon() {
    if (drawing === null) return;
    drawing = null;
    e.paint_cancel();
    scheduleDraw();
  }

  canvas.addEventListener("pointerup", finish);
  canvas.addEventListener("pointercancel", abandon);
  canvas.addEventListener("lostpointercapture", (ev) => {
    if (ev.pointerId === drawing) abandon();
  });
  window.addEventListener("blur", abandon);

  // ---- controls ---------------------------------------------------------------

  for (const input of [preset, size, opacity, color]) input.addEventListener("input", applyBrush);
  for (const input of toolInputs) input.addEventListener("change", applyBrush);

  layer.addEventListener("change", () => {
    e.paint_set_layer(Number(layer.value));
  });

  const doUndo = () => {
    if (drawing === null && e.paint_undo()) scheduleDraw();
  };
  const doRedo = () => {
    if (drawing === null && e.paint_redo()) scheduleDraw();
  };
  undo.addEventListener("click", doUndo);
  redo.addEventListener("click", doRedo);

  // Keyboard (lesson 68): the usual shortcuts while focus is inside the studio.
  root.addEventListener("keydown", (ev) => {
    if (!(ev.ctrlKey || ev.metaKey)) return;
    const key = ev.key.toLowerCase();
    if (key === "z" && !ev.shiftKey) doUndo();
    else if ((key === "z" && ev.shiftKey) || key === "y") doRedo();
    else return;
    ev.preventDefault();
  });

  save.addEventListener("click", () => {
    const length = e.paint_export_png();
    if (!length) {
      status.textContent = "Saving failed: the engine could not encode the picture.";
      return;
    }
    // Copied out: the bytes live in the engine's memory and are freed by the
    // next export.
    const bytes = new Uint8Array(e.memory.buffer, e.paint_png(), length).slice();
    const url = URL.createObjectURL(new Blob([bytes], { type: "image/png" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "painting.png";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });

  // For the browser gate: what the engine holds, and whether this build draws
  // the demo picture the native tests pinned.
  Object.assign(root, {
    engineHash: () => {
      e.paint_render();
      return e.paint_hash() >>> 0;
    },
    engineSelfTest: () => e.paint_self_test() === 1,
  });

  applyBrush();
  draw();
  root.dataset.ready = "true";
}
