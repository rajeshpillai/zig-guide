/**
 * Festive decorations: the footer switch, and marigold petals animated by
 * tinyfly (https://github.com/algorisys-oss/tinyfly).
 *
 * The garland is pure CSS keyed off `data-festive`, which the inline script in
 * `Base.astro` sets before first paint. This file does the two things that
 * cannot happen that early: it wires the switch, and it drops the petals.
 *
 * Petals fall, and Mushak (Ganesha's mouse, carrying a laddoo) runs one lap
 * of the screen, once per browser session: not on every page and never in a
 * loop. Motion over prose pulls the eye off the sentence being read, and a
 * guide is read. Under `prefers-reduced-motion` they do not fall at all, and
 * tinyfly is never fetched.
 *
 * tinyfly is loaded as a classic script from `public/vendor/tinyfly/`, not
 * with `import()`. Vite rewrites a dynamic import even for a file it only
 * serves out of `public/`, which is the trap the Lane Dodger embed documents.
 */

interface Tinyfly {
  to(target: Element, vars: Record<string, unknown>): unknown;
  fromTo(target: Element, from: Record<string, unknown>, to: Record<string, unknown>): unknown;
  live: { killTweensOf(target: Element | Element[]): void };
}

declare global {
  interface Window {
    tinyfly?: Tinyfly;
  }
}

const KEY = "festive";
const SESSION_KEY = "festive-petals";
const PETALS = 18;

const root = document.documentElement;
const meta = document.querySelector<HTMLMetaElement>('meta[name="festival"]');
const row = document.querySelector<HTMLElement>(".festive-pick");
const toggle = row?.querySelector<HTMLButtonElement>(".festive-switch");

function inWindow(): { id: string } | null {
  const [id, start, end] = (meta?.content ?? "").split(" ");
  const now = Date.now();
  return id && now >= Date.parse(start) && now < Date.parse(end) ? { id } : null;
}

const festival = inWindow();

function loadTinyfly(): Promise<Tinyfly> {
  if (window.tinyfly) return Promise.resolve(window.tinyfly);
  return new Promise((ok, fail) => {
    const s = document.createElement("script");
    s.src = `${import.meta.env.BASE_URL}vendor/tinyfly/tinyfly.iife.js`;
    s.onload = () => (window.tinyfly ? ok(window.tinyfly) : fail(new Error("tinyfly: no global")));
    s.onerror = () => fail(new Error("tinyfly: failed to load"));
    document.head.appendChild(s);
  });
}

let layer: HTMLElement | null = null;

function clearPetals() {
  if (!layer) return;
  window.tinyfly?.live.killTweensOf([...layer.children, ...layer.querySelectorAll(".mouse-feet")]);
  layer.remove();
  layer = null;
}

const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);

// Faces right, so `autoRotate` points its nose along the path. Colours come
// from the `--festive-*` tokens through the classes in global.css.
const MOUSE_SVG = `<svg viewBox="0 0 52 30" width="52" height="30" focusable="false">
  <path class="mouse-tail" d="M9 20C1 21 0 12 5 9" />
  <g class="mouse-feet"><ellipse cx="15" cy="27" rx="3" ry="1.6" /><ellipse cx="28" cy="27" rx="3" ry="1.6" /></g>
  <ellipse class="mouse-fur" cx="21" cy="19" rx="13" ry="8" />
  <ellipse class="mouse-fur" cx="35" cy="17" rx="8" ry="6.5" />
  <circle class="mouse-fur" cx="31" cy="9.5" r="4.2" />
  <circle class="mouse-pink" cx="31" cy="9.5" r="2.5" />
  <circle class="mouse-eye" cx="37.5" cy="15" r="1.3" />
  <circle class="mouse-pink" cx="43" cy="18" r="1.5" />
  <circle class="mouse-laddoo" cx="47" cy="22" r="3.6" />
</svg>`;

/**
 * One lap: in from the left along the bottom in hops, up the right edge,
 * across under the garland, down the left edge, and off to the right. The
 * points are offsets from where the mouse is laid out, just off-screen at
 * bottom left, which is what tinyfly's `motionPath` measures from.
 */
function mouseLap(w: number, h: number): { points: { x: number; y: number }[]; seconds: number } {
  const ox = -70;
  const bottom = h - 36;
  const top = (document.querySelector(".topbar")?.getBoundingClientRect().bottom ?? 52) + 28;
  const right = w - 58;
  const left = 6;
  const abs: [number, number][] = [[ox, bottom]];
  const hops = Math.max(2, Math.round(right / 160));
  for (let i = 1; i <= hops; i++) {
    const x = (right * i) / hops;
    abs.push([x - right / hops / 2, bottom - 26], [x, bottom]);
  }
  abs.push([right, top], [left, top], [left, bottom], [w * 0.45, bottom - 30], [w + 80, bottom]);
  const points = abs.map(([x, y]) => ({ x: x - ox, y: y - bottom }));
  let length = 0;
  for (let i = 1; i < abs.length; i++) {
    length += Math.hypot(abs[i][0] - abs[i - 1][0], abs[i][1] - abs[i - 1][1]);
  }
  return { points, seconds: Math.min(16, Math.max(8, length / 280)) };
}

async function celebrate() {
  const tf = await loadTinyfly();
  // The reader may have switched decorations off while the script loaded, or
  // switched them on twice.
  if (!root.dataset.festive || layer) return;

  layer = document.createElement("div");
  layer.className = "festive-petals";
  layer.setAttribute("aria-hidden", "true");

  const w = window.innerWidth;
  const h = window.innerHeight;
  const petals: HTMLElement[] = [];
  for (let i = 0; i < PETALS; i++) {
    const p = document.createElement("span");
    p.className = i % 3 === 0 ? "festive-petal alt" : "festive-petal";
    p.style.left = `${rand(0, w)}px`;
    petals.push(p);
    layer.appendChild(p);
  }
  const mouse = document.createElement("span");
  mouse.className = "festive-mouse";
  mouse.innerHTML = MOUSE_SVG;
  mouse.style.left = "-70px";
  mouse.style.top = `${h - 36}px`;
  layer.appendChild(mouse);
  document.body.appendChild(layer);

  // The garland settles into place once, as the petals start.
  const toran = document.querySelector(".festive-toran svg");
  if (toran) {
    tf.fromTo(toran, { y: -14, opacity: 0 }, { y: 0, opacity: 1, duration: 1.1, ease: "back.out" });
  }

  let finished = 0;
  const tweens = petals.length + 1;
  const done = () => {
    if (++finished === tweens) clearPetals();
  };

  const lap = mouseLap(w, h);
  const feet = mouse.querySelector(".mouse-feet");
  if (feet) {
    tf.to(feet, { y: -1.5, duration: 0.09, repeat: -1, yoyo: true, ease: "none" });
  }
  tf.to(mouse, {
    motionPath: { path: lap.points, curviness: 0.7, autoRotate: true },
    duration: lap.seconds,
    delay: 0.6,
    ease: "none",
    onComplete: done,
  });

  for (const p of petals) {
    // tinyfly never reads computed style, so each start state is given
    // explicitly rather than left to whatever CSS placed there.
    tf.fromTo(
      p,
      { y: -24, x: 0, rotate: rand(0, 360), opacity: 1 },
      {
        y: h + 24,
        x: rand(-80, 80),
        rotate: rand(360, 900),
        opacity: 0.25,
        duration: rand(4, 6.5),
        delay: rand(0, 1.8),
        ease: "sine.inOut",
        onComplete: done,
      },
    );
  }
}

function paint() {
  toggle?.setAttribute("aria-pressed", String(Boolean(root.dataset.festive)));
}

if (festival && row && toggle) {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  row.hidden = false;
  paint();

  toggle.addEventListener("click", () => {
    const on = !root.dataset.festive;
    if (on) {
      root.dataset.festive = festival.id;
      // Switching back on is asking to see it, so it plays again.
      if (!still && !layer) celebrate().catch((e) => console.warn(e));
    } else {
      delete root.dataset.festive;
      clearPetals();
    }
    try {
      localStorage.setItem(KEY, on ? "on" : "off");
    } catch {
      // Private mode: the choice lasts until the next page.
    }
    paint();
  });

  let fallen = false;
  try {
    fallen = sessionStorage.getItem(SESSION_KEY) === "1";
    sessionStorage.setItem(SESSION_KEY, "1");
  } catch {
    // No session storage: petals on every page is worse than none.
    fallen = true;
  }

  if (root.dataset.festive && !fallen && !still) {
    const idle = window.requestIdleCallback ?? ((fn: () => void) => setTimeout(fn, 300));
    idle(() => {
      celebrate().catch((e) => console.warn(e));
    });
  }
}
