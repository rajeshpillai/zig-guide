/**
 * The light/dark toggle.
 *
 * The default is no choice at all: `color-scheme: light` in the stylesheet
 * means an untouched page opens light, and that is the state this script
 * starts from. It used to be `light dark`, which followed the reader's system
 * setting, and the difference matters here rather than in the stylesheet: with
 * no attribute set there is now one answer to what the reader is looking at
 * instead of one that has to be asked of the machine. `data-theme` on <html>
 * exists only once someone overrides it, which is why the inline script in
 * `Base.astro` has so little to do and can run before first paint.
 *
 * Progressive enhancement, on the same terms as the search box: the button is
 * `hidden` in the markup and revealed here. With JS off there is no toggle and
 * the system setting still decides, so nothing is broken, only unavailable.
 */

const KEY = "theme";
type Theme = "light" | "dark";

const root = document.documentElement;
const button = document.querySelector<HTMLButtonElement>(".theme-toggle");

/** What the reader is actually looking at. No attribute means light. */
function current(): Theme {
  const set = root.dataset.theme;
  if (set === "light" || set === "dark") return set;
  return "light";
}

/**
 * The icon shows the theme the click would produce, and the label says it in
 * words. A sun on its own is ambiguous: it reads equally as "you are in light
 * mode" and "press for light mode", and which one a given site means is not
 * something a reader should have to work out by pressing it.
 */
function paint(): void {
  if (!button) return;
  const next: Theme = current() === "dark" ? "light" : "dark";
  button.dataset.next = next;
  button.setAttribute("aria-label", `Switch to ${next} theme`);
  button.setAttribute("title", `Switch to ${next} theme`);
}

if (button) {
  button.hidden = false;
  paint();

  button.addEventListener("click", () => {
    const next: Theme = current() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem(KEY, next);
    } catch {
      // Private mode: the choice holds for this page and no longer.
    }
    paint();
  });
}
