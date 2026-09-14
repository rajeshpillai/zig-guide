/**
 * Festive decorations: the footer switch, and marigold petals animated by
 * tinyfly (https://github.com/algorisys-oss/tinyfly).
 *
 * The garland is pure CSS keyed off `data-festive`, which the inline script in
 * `Base.astro` sets before first paint. This file does the two things that
 * cannot happen that early: it wires the switch, and it drops the petals.
 *
 * Petals fall once per browser session, not on every page and never in a
 * loop. Motion over prose pulls the eye off the sentence being read, and a
 * guide is read. Under `prefers-reduced-motion` they do not fall at all, and
 * tinyfly is never fetched.
 *
 * tinyfly is loaded as a classic script from `public/vendor/tinyfly/`, not
 * with `import()`. Vite rewrites a dynamic import even for a file it only
 * serves out of `public/`, which is the trap the Lane Dodger embed documents.
 */

interface Tinyfly {
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
  window.tinyfly?.live.killTweensOf([...layer.children]);
  layer.remove();
  layer = null;
}

const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);

async function dropPetals() {
  const tf = await loadTinyfly();
  // The reader may have switched decorations off while the script loaded.
  if (!root.dataset.festive) return;

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
  document.body.appendChild(layer);

  // The garland settles into place once, as the petals start.
  const toran = document.querySelector(".festive-toran svg");
  if (toran) {
    tf.fromTo(toran, { y: -14, opacity: 0 }, { y: 0, opacity: 1, duration: 1.1, ease: "back.out" });
  }

  let finished = 0;
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
        onComplete: () => {
          if (++finished === petals.length) clearPetals();
        },
      },
    );
  }
}

function paint() {
  toggle?.setAttribute("aria-pressed", String(Boolean(root.dataset.festive)));
}

if (festival && row && toggle) {
  row.hidden = false;
  paint();

  toggle.addEventListener("click", () => {
    const on = !root.dataset.festive;
    if (on) root.dataset.festive = festival.id;
    else {
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

  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (root.dataset.festive && !fallen && !still) {
    const idle = window.requestIdleCallback ?? ((fn: () => void) => setTimeout(fn, 300));
    idle(() => {
      dropPetals().catch((e) => console.warn(e));
    });
  }
}
