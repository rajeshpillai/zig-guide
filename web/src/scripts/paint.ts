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
    contact: number, bristles: number, pickup: number, drain: number,
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
  paint_alloc(len: number): number;
  paint_free(ptr: number, len: number): void;
  paint_file(): number;
  paint_error(): number;
  paint_error_len(): number;
  paint_project_save(): number;
  paint_project_open(ptr: number, len: number): number;
  paint_width(): number;
  paint_height(): number;
  paint_active_layer(): number;
  paint_preset_save(namePtr: number, nameLen: number): number;
  paint_preset_open(ptr: number, len: number): number;
  paint_preset_name(): number;
  paint_preset_name_len(): number;
  paint_brush_value(index: number): number;
}

/** What each refusal from the engine means, in words a reader can act on. */
const REFUSALS: Record<string, string> = {
  NotAProject: "This is not a project file from this program.",
  NewerVersion: "This file was saved by a newer version of the program.",
  BadSize: "The file gives a picture size this program does not accept.",
  BadLayers: "The file's layer information is damaged.",
  Truncated: "The file is cut short.",
  BadPixels: "The file's pixel data is damaged.",
  NotPremultiplied: "The file's pixel data is damaged.",
  TrailingBytes: "The file has extra data at the end.",
  NotAPreset: "This is not a brush preset.",
  BadName: "The preset's name is empty, too long, or has control characters.",
  BadColor: "The preset's colour is not written as #rrggbb.",
  OutOfRange: "One of the preset's settings is outside what the brush allows.",
  OutOfMemory: "There is not enough memory to open this file.",
};

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
  /** How much of the paper's grain the brush reaches, 0 to 1. */
  contact: number;
  /** Separate hairs across the tip; 0 is a solid tip. */
  bristles: number;
  /** How much of the paint underneath the brush picks up at each dab, 0 to 1. */
  pickup: number;
  /** Share of a full load used per 100 pixels; 0 never runs dry. */
  drain: number;
}

const PRESETS: Record<string, Preset> = {
  pencil: { hardness: 0.9, flow: 0.9, spacing: 0.15, follow: 0.6, pressure: 0.6, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  ink: { hardness: 0.95, flow: 1, spacing: 0.1, follow: 0.35, pressure: 1, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  soft: { hardness: 0.1, flow: 0.12, spacing: 0.2, follow: 0.5, pressure: 0.3, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  airbrush: { hardness: 0, flow: 0.04, spacing: 0.1, follow: 0.8, pressure: 0, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  calligraphy: { hardness: 0.95, flow: 1, spacing: 0.08, follow: 0.4, pressure: 0.4, jitter: 0, scatter: 0, aspect: 0.2, angle: -45, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  ribbon: { hardness: 0.8, flow: 1, spacing: 0.08, follow: 0.4, pressure: 0.5, jitter: 0, scatter: 0, aspect: 0.25, angle: 90, followDirection: true, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  spray: { hardness: 0.6, flow: 0.7, spacing: 1.2, follow: 1, pressure: 0, jitter: 0.6, scatter: 2.5, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0, drain: 0 },
  dry: { hardness: 0.8, flow: 0.9, spacing: 0.04, follow: 0.5, pressure: 0.4, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 0.55, bristles: 9, pickup: 0, drain: 0 },
  oil: { hardness: 0.7, flow: 1, spacing: 0.05, follow: 0.5, pressure: 0.4, jitter: 0, scatter: 0, aspect: 1, angle: 0, followDirection: false, contact: 1, bristles: 0, pickup: 0.12, drain: 0.2 },
};

const TOOLS = { brush: 0, eraser: 1 } as const;

export async function startPaint(root: HTMLElement, wasmUrl: string): Promise<void> {
  const canvas = root.querySelector<HTMLCanvasElement>(".paint-canvas")!;
  const status = root.querySelector<HTMLElement>(".paint-status")!;
  const ctx = canvas.getContext("2d")!;
  let width = canvas.width;
  let height = canvas.height;

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
      seed, p.contact, p.bristles, p.pickup, p.drain,
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

  // ---- files (projects and brush presets) -------------------------------------

  const text = new TextDecoder();
  const engineText = (ptr: number, len: number) => text.decode(new Uint8Array(e.memory.buffer, ptr, len));

  function download(length: number, name: string, type: string) {
    // Copied out: the bytes live in the engine's memory and the next file
    // the engine writes frees them.
    const bytes = new Uint8Array(e.memory.buffer, e.paint_file(), length).slice();
    const url = URL.createObjectURL(new Blob([bytes], { type }));
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  /** Copy a file's bytes into the engine, run `use` on them, and free them. */
  async function withFile(file: File, use: (ptr: number, len: number) => boolean): Promise<boolean> {
    const bytes = new Uint8Array(await file.arrayBuffer());
    const ptr = e.paint_alloc(bytes.length);
    if (!ptr && bytes.length) {
      status.textContent = REFUSALS.OutOfMemory;
      return false;
    }
    new Uint8Array(e.memory.buffer, ptr, bytes.length).set(bytes);
    try {
      if (use(ptr, bytes.length)) return true;
      const reason = engineText(e.paint_error(), e.paint_error_len());
      status.textContent = `Not opened. ${REFUSALS[reason] ?? reason}`;
      return false;
    } finally {
      e.paint_free(ptr, bytes.length);
    }
  }

  control<HTMLButtonElement>("project-save").addEventListener("click", () => {
    const length = e.paint_project_save();
    if (length) download(length, "painting.zpaint", "application/octet-stream");
    else status.textContent = "Saving failed: the engine could not write the project.";
  });

  const projectFile = control<HTMLInputElement>("project-file");
  control<HTMLButtonElement>("project-open").addEventListener("click", () => projectFile.click());
  projectFile.addEventListener("change", async () => {
    const file = projectFile.files?.[0];
    projectFile.value = "";
    if (!file || drawing !== null) return;
    if (!(await withFile(file, (ptr, len) => e.paint_project_open(ptr, len) === 1))) return;
    // The project may be a different size, so the canvas follows it.
    canvas.width = e.paint_width();
    canvas.height = e.paint_height();
    width = canvas.width;
    height = canvas.height;
    layer.value = String(e.paint_active_layer());
    status.textContent = `Opened ${file.name}.`;
    scheduleDraw();
  });

  control<HTMLButtonElement>("preset-save").addEventListener("click", () => {
    applyBrush();
    const name = new TextEncoder().encode(preset.options[preset.selectedIndex].text.slice(0, 40));
    const ptr = e.paint_alloc(name.length);
    new Uint8Array(e.memory.buffer, ptr, name.length).set(name);
    const length = e.paint_preset_save(ptr, name.length);
    e.paint_free(ptr, name.length);
    if (length) download(length, "brush.json", "application/json");
  });

  const presetFile = control<HTMLInputElement>("preset-file");
  control<HTMLButtonElement>("preset-open").addEventListener("click", () => presetFile.click());
  presetFile.addEventListener("change", async () => {
    const file = presetFile.files?.[0];
    presetFile.value = "";
    if (!file) return;
    if (!(await withFile(file, (ptr, len) => e.paint_preset_open(ptr, len) === 1))) return;
    // The engine checked the preset. Read its settings back so the controls
    // show them, and list it in the Brush menu under its own name.
    const v = (i: number) => e.paint_brush_value(i);
    const name = engineText(e.paint_preset_name(), e.paint_preset_name_len());
    const id = `file:${name}`;
    PRESETS[id] = {
      hardness: v(1), flow: v(2), spacing: v(4), follow: v(5), pressure: v(6), jitter: v(7),
      scatter: v(8), aspect: v(9), angle: v(10), followDirection: v(11) === 1,
      contact: v(15), bristles: v(16), pickup: v(17), drain: v(18),
    };
    if (![...preset.options].some((o) => o.value === id)) preset.add(new Option(name, id));
    preset.value = id;
    size.value = String(Math.round(v(0)));
    opacity.value = String(Math.round(v(3) * 100));
    color.value = "#" + [v(12), v(13), v(14)].map((c) => c.toString(16).padStart(2, "0")).join("");
    applyBrush();
    status.textContent = `Loaded the brush "${name}".`;
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
