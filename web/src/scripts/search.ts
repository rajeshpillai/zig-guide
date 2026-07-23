/**
 * Client-side chapter search. The index is a static JSON file emitted at
 * build time (`/search-index.json`), fetched once on first interaction.
 * Progressive enhancement: the markup is hidden until this runs, so with JS
 * off there is no dead search box.
 */

interface Record {
  title: string;
  section: string;
  group: string | null;
  description: string;
  url: string;
  headings: string[];
  text: string;
}

interface Hit {
  record: Record;
  score: number;
  snippet: string;
}

const container = document.querySelector<HTMLDivElement>(".search");
const input = document.querySelector<HTMLInputElement>(".search-input");
const results = document.querySelector<HTMLDivElement>(".search-results");

if (container && input && results) {
  container.hidden = false;

  let index: Record[] | null = null;
  let loading: Promise<Record[]> | null = null;
  let hits: Hit[] = [];
  let active = -1;

  function loadIndex(): Promise<Record[]> {
    if (index) return Promise.resolve(index);
    if (!loading) {
      loading = fetch(`${import.meta.env.BASE_URL}search-index.json`)
        .then((r) => (r.ok ? r.json() : []))
        .then((data: Record[]) => (index = data))
        .catch(() => (index = []));
    }
    return loading;
  }

  function tokenize(q: string): string[] {
    return q.toLowerCase().split(/\s+/).filter(Boolean);
  }

  // Score a record against the query tokens. Every token must appear
  // somewhere (AND), and where it appears sets its weight: a title match
  // beats a heading match beats a body match. Whole-word and prefix matches
  // score above a bare substring so "map" ranks HashMaps above a passing
  // mention of "unmap".
  function scoreRecord(rec: Record, tokens: string[]): number {
    const title = rec.title.toLowerCase();
    const heads = rec.headings.join("  ").toLowerCase();
    const desc = rec.description.toLowerCase();
    const body = rec.text.toLowerCase();
    const context = `${rec.section} ${rec.group ?? ""}`.toLowerCase();

    let total = 0;
    for (const t of tokens) {
      let best = 0;
      if (title === t) best = 100;
      else if (wordHit(title, t)) best = 40;
      else if (title.includes(t)) best = 22;
      else if (wordHit(heads, t)) best = 16;
      else if (wordHit(desc, t)) best = 12;
      else if (context.includes(t)) best = 10;
      else if (wordHit(body, t)) best = 6;
      else if (body.includes(t)) best = 3;
      if (best === 0) return 0; // token missing entirely: reject
      total += best;
    }
    return total;
  }

  function wordHit(haystack: string, token: string): boolean {
    let from = 0;
    for (;;) {
      const i = haystack.indexOf(token, from);
      if (i === -1) return false;
      const before = i === 0 ? " " : haystack[i - 1];
      if (!/[a-z0-9]/.test(before)) return true; // start of a word
      from = i + token.length;
    }
  }

  function makeSnippet(rec: Record, tokens: string[]): string {
    const hay = rec.text;
    const lower = hay.toLowerCase();
    let at = -1;
    for (const t of tokens) {
      const i = lower.indexOf(t);
      if (i !== -1 && (at === -1 || i < at)) at = i;
    }
    if (at === -1) return rec.description || hay.slice(0, 120);
    const start = Math.max(0, at - 40);
    const end = Math.min(hay.length, at + 90);
    return (start > 0 ? "…" : "") + hay.slice(start, end).trim() + (end < hay.length ? "…" : "");
  }

  function escape(s: string): string {
    return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
  }

  function highlight(text: string, tokens: string[]): string {
    let out = escape(text);
    for (const t of tokens) {
      if (!t) continue;
      const re = new RegExp(`(${t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi");
      out = out.replace(re, "<mark>$1</mark>");
    }
    return out;
  }

  function run(query: string): void {
    const tokens = tokenize(query);
    if (!index || tokens.length === 0) {
      hits = [];
      render(tokens);
      return;
    }
    hits = index
      .map((rec) => ({ record: rec, score: scoreRecord(rec, tokens), snippet: "" }))
      .filter((h) => h.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 8)
      .map((h) => ({ ...h, snippet: makeSnippet(h.record, tokens) }));
    active = hits.length ? 0 : -1;
    render(tokens);
  }

  function render(tokens: string[]): void {
    if (!results || !input) return;
    const open = tokens.length > 0;
    input.setAttribute("aria-expanded", String(open));
    if (!open) {
      results.hidden = true;
      results.innerHTML = "";
      return;
    }
    if (hits.length === 0) {
      results.hidden = false;
      results.innerHTML = `<p class="search-empty">No chapters match “${escape(tokens.join(" "))}”.</p>`;
      return;
    }
    results.hidden = false;
    results.innerHTML = hits
      .map((h, i) => {
        const crumb = h.record.group
          ? `${escape(h.record.section)} › ${escape(h.record.group)}`
          : escape(h.record.section);
        return `<a class="search-hit${i === active ? " is-active" : ""}" href="${h.record.url}" role="option" id="search-hit-${i}" aria-selected="${i === active}">
          <span class="search-hit-crumb">${crumb}</span>
          <span class="search-hit-title">${highlight(h.record.title, tokens)}</span>
          <span class="search-hit-snippet">${highlight(h.snippet, tokens)}</span>
        </a>`;
      })
      .join("");
    syncActive();
  }

  function syncActive(): void {
    if (!results) return;
    const nodes = results.querySelectorAll<HTMLElement>(".search-hit");
    nodes.forEach((n, i) => {
      n.classList.toggle("is-active", i === active);
      n.setAttribute("aria-selected", String(i === active));
    });
    input?.setAttribute("aria-activedescendant", active >= 0 ? `search-hit-${active}` : "");
    nodes[active]?.scrollIntoView({ block: "nearest" });
  }

  function move(delta: number): void {
    if (hits.length === 0) return;
    active = (active + delta + hits.length) % hits.length;
    syncActive();
  }

  function go(): void {
    const hit = hits[active] ?? hits[0];
    if (hit) window.location.href = hit.record.url;
  }

  function close(): void {
    if (!results) return;
    results.hidden = true;
    input?.setAttribute("aria-expanded", "false");
  }

  input.addEventListener("focus", () => {
    loadIndex().then(() => run(input.value));
  });

  input.addEventListener("input", () => {
    loadIndex().then(() => run(input.value));
  });

  input.addEventListener("keydown", (e) => {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        move(1);
        break;
      case "ArrowUp":
        e.preventDefault();
        move(-1);
        break;
      case "Enter":
        if (hits.length) {
          e.preventDefault();
          go();
        }
        break;
      case "Escape":
        if (input.value) {
          input.value = "";
          run("");
        } else {
          input.blur();
          close();
        }
        break;
    }
  });

  // Click-away closes the panel; a click on a result follows its link.
  document.addEventListener("click", (e) => {
    if (!container.contains(e.target as Node)) close();
  });

  // "/" focuses search from anywhere; Cmd/Ctrl+K too. Ignore when the
  // reader is already typing in a field or editing a snippet.
  document.addEventListener("keydown", (e) => {
    const target = e.target as HTMLElement;
    const typing =
      target.tagName === "INPUT" ||
      target.tagName === "TEXTAREA" ||
      target.isContentEditable;
    if ((e.key === "/" && !typing) || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k")) {
      e.preventDefault();
      input.focus();
      input.select();
    }
  });
}
