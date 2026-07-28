/**
 * Remember which sidebar sections the reader has expanded or collapsed, so the
 * choice survives navigation and reloads.
 *
 * The markup is server-rendered with one section open (the current one). This
 * enhancement restores the reader's own open/closed state on top of that, and
 * always reveals the branch containing the current page so you can see where
 * you are. Progressive enhancement: with JS off the CSS-only <details> keep
 * working, just without memory.
 */

const KEY = "nav-open";

type State = Record<string, boolean>;

function load(): State {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as State) : {};
  } catch {
    return {};
  }
}

function save(state: State): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(state));
  } catch {
    // Private mode or a full quota: the sidebar simply stops remembering.
  }
}

const state = load();
const groups = document.querySelectorAll<HTMLDetailsElement>("details[data-nav-key]");

// Applying saved state fires `toggle`; ignore those synthetic events so only a
// real click persists (otherwise revealing the active branch would creep every
// visited section permanently open).
let restoring = true;

for (const details of groups) {
  const key = details.dataset.navKey;
  if (!key) continue;

  if (key in state) details.open = state[key];
  // The active branch always wins, so navigating in never lands you on a page
  // whose section is collapsed out of view.
  if (details.querySelector('[aria-current="page"]')) details.open = true;

  details.addEventListener("toggle", () => {
    if (restoring) return;
    state[key] = details.open;
    save(state);
  });
}

requestAnimationFrame(() => {
  restoring = false;
});

/**
 * Bring the current chapter into view inside the sidebar.
 *
 * Opening its section is not enough on its own. The sidebar is its own scroll
 * container (`overflow-y: auto` under a `max-height`), and with four tracks and
 * a hundred and thirty chapters the active link is often below the fold, so
 * arriving from search or from a link would land you on a page whose entry in
 * the sidebar you cannot see. The sidebar would be showing whatever the last
 * page happened to leave it showing.
 *
 * Only `scrollTop` on the sidebar is touched, never `scrollIntoView`, which
 * would scroll the document as well and move the chapter you just opened.
 */
function revealCurrent(): void {
  const sidebar = document.querySelector<HTMLElement>(".sidebar");
  const link = sidebar?.querySelector<HTMLElement>('a[aria-current="page"]');
  if (!sidebar || !link) return;

  // Hidden (the phone drawer, or the folded rail) has no layout to measure.
  if (sidebar.scrollHeight <= sidebar.clientHeight) return;

  const top = link.getBoundingClientRect().top - sidebar.getBoundingClientRect().top;
  const bottom = top + link.offsetHeight;

  // Already visible: leave the scroll where the reader had it.
  if (top >= 0 && bottom <= sidebar.clientHeight) return;

  const centred = sidebar.scrollTop + top - (sidebar.clientHeight - link.offsetHeight) / 2;
  sidebar.scrollTop = Math.max(0, Math.min(centred, sidebar.scrollHeight - sidebar.clientHeight));
}

revealCurrent();

// Both toggles reveal a sidebar that was `display: none`, so it had no
// measurable layout above and this is the first chance to place it.
for (const id of ["nav-toggle", "rail-toggle"]) {
  document
    .getElementById(id)
    ?.addEventListener("change", () => requestAnimationFrame(revealCurrent));
}

/**
 * Whether the whole sidebar is folded away, on wide screens. Restoring it is
 * the job of the inline script in the layout (this module runs too late to
 * avoid a flash); all that is left here is writing the reader's choice down.
 */
const RAIL_KEY = "nav-rail";
const rail = document.getElementById("rail-toggle") as HTMLInputElement | null;

rail?.addEventListener("change", () => {
  try {
    localStorage.setItem(RAIL_KEY, rail.checked ? "closed" : "open");
  } catch {
    // Same as above: the sidebar simply stops remembering.
  }
});
