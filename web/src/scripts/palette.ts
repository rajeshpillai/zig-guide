/**
 * The palette picker.
 *
 * Two attributes on <html> decide what a reader sees, and they are
 * independent. `data-theme` narrows `color-scheme` and so picks a column out
 * of every `light-dark()` pair; `data-palette` picks which set of pairs is in
 * force. Neither one reaches into the other, which is why three palettes give
 * six looks and why no palette can be reached in one mode only.
 *
 * The default is the absence of the attribute rather than a value of it, the
 * same as the theme: an untouched page is Paper in its light column, and
 * `data-palette` exists on <html> only once someone has chosen otherwise. That is what leaves the inline script in
 * `Base.astro` with almost nothing to do before first paint.
 *
 * Progressive enhancement, on the contract the search box and the theme toggle
 * already keep: the row is `hidden` in the markup and revealed here, because a
 * control that cannot do anything is worse than no control at all. With JS off
 * there is no picker and the default palette is what every reader gets.
 */

const KEY = "palette";

/** Every name a block in `global.css` actually defines. */
const PALETTES = ["paper", "zig", "nord"] as const;
type Palette = (typeof PALETTES)[number];

const isPalette = (v: unknown): v is Palette =>
  PALETTES.includes(v as Palette);

const root = document.documentElement;
const row = document.querySelector<HTMLElement>(".palette-pick");
const buttons = [
  ...document.querySelectorAll<HTMLButtonElement>("[data-palette-set]"),
];

/** What the reader is actually looking at. No attribute means the default. */
function current(): Palette {
  const set = root.dataset.palette;
  return isPalette(set) ? set : "paper";
}

/**
 * `aria-pressed` rather than a class, so the state is one thing rather than
 * two: it is what a screen reader announces and what the selected style
 * selects on, and the pair cannot drift apart.
 */
function paint(): void {
  const now = current();
  for (const button of buttons) {
    const id = button.dataset.paletteSet;
    button.setAttribute("aria-pressed", String(id === now));
  }
}

if (row && buttons.length) {
  row.hidden = false;
  paint();

  for (const button of buttons) {
    button.addEventListener("click", () => {
      const id = button.dataset.paletteSet;
      if (!isPalette(id)) return;

      // The default is written as the attribute's absence, not as the string
      // "paper". Setting it would style identically today and become a lie the
      // moment the base tokens are the thing that changes.
      if (id === "paper") delete root.dataset.palette;
      else root.dataset.palette = id;

      try {
        localStorage.setItem(KEY, id);
      } catch {
        // Private mode: the choice holds for this page and no longer.
      }
      paint();
    });
  }
}
