/**
 * The watercolour lab: pointer input and a clock in, the engine's grid out.
 *
 * The simulation is `Watercolor` in the Zig engine, and its `step` always
 * advances 1/30 of a second. This file owns the clock. Each frame it adds the
 * elapsed time to an accumulator and runs whole steps while enough time has
 * built up, at most four, so a slow machine slows the painting down instead
 * of freezing while it catches up.
 */

interface WatercolorExports {
  memory: WebAssembly.Memory;
  wc_init(): number;
  wc_width_cells(): number;
  wc_height_cells(): number;
  wc_drop(x: number, y: number, radius: number, water: number, pigment: number): void;
  wc_step(): void;
  wc_clear(): void;
  wc_set_color(r: number, g: number, b: number): void;
  wc_render(): number;
  wc_pigment(): number;
  wc_hash(): number;
}

const DT = 1 / 30;
const MAX_STEPS_PER_FRAME = 4;

export async function startWatercolor(root: HTMLElement, wasmUrl: string): Promise<void> {
  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`could not fetch the engine (HTTP ${response.status})`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  const e = instance.exports as unknown as WatercolorExports;
  if (!e.wc_init()) throw new Error("the engine could not allocate the grid");

  const canvas = root.querySelector<HTMLCanvasElement>(".wc-canvas")!;
  const ctx = canvas.getContext("2d")!;
  const cols = e.wc_width_cells();
  const rows = e.wc_height_cells();
  canvas.width = cols;
  canvas.height = rows;

  const control = <T extends HTMLElement>(name: string) =>
    root.querySelector<T>(`[data-control="${name}"]`)!;
  const play = control<HTMLButtonElement>("play");
  const clear = control<HTMLButtonElement>("clear");
  const color = control<HTMLInputElement>("color");
  const size = control<HTMLInputElement>("size");
  const clock = root.querySelector<HTMLElement>(".wc-clock")!;

  let running = true;
  let simulated = 0;

  function draw() {
    const at = e.wc_render();
    const pixels = new Uint8ClampedArray(e.memory.buffer, at, cols * rows * 4);
    ctx.putImageData(new ImageData(new Uint8ClampedArray(pixels), cols, rows), 0, 0);
    clock.textContent = `${simulated.toFixed(1)} s simulated`;
  }

  function applyColor() {
    const hex = color.value;
    e.wc_set_color(parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16));
    draw();
  }

  // ---- the clock (fixed steps from an accumulator) ----------------------------

  let accumulator = 0;
  let last: number | null = null;
  function frame(now: number) {
    if (last !== null && running) {
      accumulator += Math.min((now - last) / 1000, 1);
      let steps = 0;
      while (accumulator >= DT && steps < MAX_STEPS_PER_FRAME) {
        e.wc_step();
        simulated += DT;
        accumulator -= DT;
        steps++;
      }
      // Fell behind: drop the backlog rather than run an ever longer
      // catch-up loop. The painting slows down; the page stays responsive.
      if (steps === MAX_STEPS_PER_FRAME) accumulator = 0;
      if (steps > 0) draw();
    }
    last = now;
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  // ---- input --------------------------------------------------------------------

  /** Grid cells, whatever size CSS has made the canvas. */
  function toCells(ev: PointerEvent): [number, number] {
    const box = canvas.getBoundingClientRect();
    return [((ev.clientX - box.left) * cols) / box.width, ((ev.clientY - box.top) * rows) / box.height];
  }

  let dropping: number | null = null;
  canvas.addEventListener("pointerdown", (ev) => {
    if (ev.button !== 0) return;
    ev.preventDefault();
    canvas.setPointerCapture(ev.pointerId);
    dropping = ev.pointerId;
    const [x, y] = toCells(ev);
    e.wc_drop(x, y, Number(size.value), 1, 0.6);
    draw();
  });
  canvas.addEventListener("pointermove", (ev) => {
    if (ev.pointerId !== dropping) return;
    const [x, y] = toCells(ev);
    // Dragging lays a trail of smaller, lighter drops.
    e.wc_drop(x, y, Number(size.value) * 0.6, 0.5, 0.08);
    draw();
  });
  const stop = (ev: PointerEvent) => {
    if (ev.pointerId === dropping) dropping = null;
  };
  canvas.addEventListener("pointerup", stop);
  canvas.addEventListener("pointercancel", stop);

  play.addEventListener("click", () => {
    running = !running;
    play.textContent = running ? "Pause" : "Play";
    last = null;
  });
  clear.addEventListener("click", () => {
    e.wc_clear();
    simulated = 0;
    draw();
  });
  color.addEventListener("input", applyColor);

  // For the browser gate.
  Object.assign(root, {
    wcHash: () => {
      e.wc_render();
      return e.wc_hash() >>> 0;
    },
    wcPigment: () => e.wc_pigment(),
    wcPause: () => {
      running = false;
      play.textContent = "Play";
    },
    wcStep: (n: number) => {
      for (let i = 0; i < n; i++) e.wc_step();
      draw();
    },
  });

  applyColor();
  root.dataset.ready = "true";
}
