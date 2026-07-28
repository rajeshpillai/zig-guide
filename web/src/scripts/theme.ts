/**
 * The light/dark toggle.
 *
 * The default is no choice at all: `color-scheme: light dark` in the
 * stylesheet means an untouched page follows the reader's system setting, and
 * that is the state this script starts from. `data-theme` on <html> exists
 * only once someone overrides it, which is why the inline script in
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
const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

/** What the reader is actually looking at, override or not. */
function current(): Theme {
  const set = root.dataset.theme;
  if (set === "light" || set === "dark") return set;
  return systemDark.matches ? "dark" : "light";
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

// Someone flipping their OS between light and dark while a page is open. Only
// meaningful when they have not overridden it here, and even then all that
// changes is which way the button points: the stylesheet has already followed.
systemDark.addEventListener("change", () => {
  if (!root.dataset.theme) paint();
});
