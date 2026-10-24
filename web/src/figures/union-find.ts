/**
 * The union-find figure, built from what `23-competitive.union-find` prints
 * for the plain parent array (a merge moves one root and nothing else), and
 * for the one compressing find on node 0 that follows it.
 *
 * The plain version is the one to draw because its trace names every parent
 * change. The parser replays each "X now points at Y" and "same root" row,
 * then requires the printed parent and depth rows and the group counts. For
 * the find, it requires the printed path to follow those parents, and reads
 * the changed parents from the printed row after it.
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.union-find";
const PLAIN = "a parent array, where a merge moves one root and nothing else";
const FIND = "one compressing find on node 0 of that forest";

/** The line that starts with `label`, after `from`, as numbers. */
function row(lines: string[], from: number, label: string, name: string): number[] {
  const line = lines.slice(from).find((l) => l.trim().startsWith(`${label} `));
  check(line, name, `no "${label}" row after line ${from}`);
  return line.trim().split(/\s+/).slice(1).map(Number);
}

const R = 17;
const LEVEL = 74;
const SLOT = 58;
/** Room on the left for the lanes of arrows that go around the tree. */
const X0 = 76;
const Y0 = 34;

export async function unionFindForest(): Promise<Figure> {
  const name = "union-find-forest";
  const output = await expectedOutput(SNIPPET);
  const lines = output.split("\n");
  const n = Number(output.match(/^(\d+) nodes/)?.[1]);
  check(n > 0, name, "no node count on the first line");

  // Replay the merges.
  const parent = Array.from({ length: n }, (_, i) => i);
  const rootOf = (x: number) => {
    while (parent[x] !== x) x = parent[x];
    return x;
  };
  type Step = { a: number; b: number; ra: number; rb: number; link: [number, number] | null; groups: number };
  const steps: Step[] = [];
  let groups = n;
  for (const line of block(output, PLAIN, name).slice(1)) {
    const m = line.match(/^\s*(\d+)-(\d+)\s+(\d+)\s+\d+\s+(\d+)\s+\d+\s+(?:(\d+) now points at (\d+)|same root)\s+(\d+)$/);
    if (!m) continue;
    const [a, b, ra, rb] = [1, 2, 3, 4].map((k) => Number(m[k]));
    check(rootOf(a) === ra && rootOf(b) === rb, name, `edge ${a}-${b}: the printed roots are not the replayed ones`);
    let link: [number, number] | null = null;
    if (m[5] !== undefined) {
      link = [Number(m[5]), Number(m[6])];
      check(link[0] === ra && link[1] === rb, name, `edge ${a}-${b}: the link is not root a to root b`);
      parent[link[0]] = link[1];
      groups -= 1;
    } else {
      check(ra === rb, name, `edge ${a}-${b} says "same root", but the roots differ`);
    }
    check(Number(m[7]) === groups, name, `edge ${a}-${b}: ${m[7]} groups printed, ${groups} replayed`);
    steps.push({ a, b, ra, rb, link, groups });
  }
  check(steps.length > 0, name, "no merge rows");
  const at = lines.findIndex((l) => l.trim() === PLAIN);
  check(row(lines, at, "parent", name).join(" ") === parent.join(" "), name, "the replayed parents are not the printed row");
  const depth = parent.map((_, i) => {
    let d = 0;
    for (let x = i; parent[x] !== x; x = parent[x]) d += 1;
    return d;
  });
  check(row(lines, at, "depth", name).join(" ") === depth.join(" "), name, "the depths of the replayed forest are not the printed row");

  // The compressing find.
  const findLines = block(output, FIND, name);
  const before = findLines.find((l) => l.includes("path before"))?.match(/path before\s+(.*)$/)?.[1].split(" -> ").map(Number);
  check(before, name, "no path before the find");
  before.slice(0, -1).forEach((x, k) => check(parent[x] === before[k + 1], name, `the path steps from ${x} to ${before[k + 1]}, which is not its parent`));
  const after = row(findLines, 0, "parent", name);
  const moved = after.map((p, i) => (p !== parent[i] ? i : -1)).filter((i) => i >= 0);
  check(moved.length > 0, name, "the find changed no parent");

  // Lay out the final forest: leaves take slots left to right, a parent sits
  // above the middle of its children.
  const children = parent.map(() => [] as number[]);
  parent.forEach((p, i) => p !== i && children[p].push(i));
  const roots = parent.map((p, i) => (p === i ? i : -1)).filter((i) => i >= 0);
  const x = new Array<number>(n);
  let slot = 0;
  const place = (v: number): number => {
    if (children[v].length === 0) x[v] = X0 + R + slot++ * SLOT;
    else {
      const xs = children[v].map(place);
      x[v] = (xs[0] + xs[xs.length - 1]) / 2;
    }
    return x[v];
  };
  roots.forEach((r) => {
    place(r);
    slot += 0.5;
  });
  const y = (v: number) => Y0 + R + depth[v] * LEVEL;
  const width = X0 * 2 + slot * SLOT;
  const height = Y0 + R * 2 + Math.max(...depth) * LEVEL + 20;

  // Every arrow the figure will ever show, drawn now and faded in when needed.
  const links = new Map<string, [number, number]>();
  for (const s of steps) if (s.link) links.set(`${s.link[0]}-${s.link[1]}`, s.link);
  for (const i of moved) links.set(`${i}-${after[i]}`, [i, after[i]]);
  let svg = `<defs><marker id="uf-head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="var(--muted)"/></marker></defs>`;
  // An arrow to the parent one level up is straight. An arrow that skips
  // levels (path compression makes them) would cross the nodes it skips, so
  // it goes around the outside of the tree instead: out of its node to the
  // left, up a lane of its own in the left margin, and into the root from the
  // left at its own height. A longer skip takes an outer lane, so two such
  // arrows never share one.
  const towards = (px: number, py: number, qx: number, qy: number, d: number) => {
    const len = Math.hypot(qx - px, qy - py);
    return [px + ((qx - px) / len) * d, py + ((qy - py) / len) * d];
  };
  const around = [...links.entries()]
    .filter(([, [from, to]]) => depth[from] - depth[to] > 1)
    .sort(([, [a, pa]], [, [b, pb]]) => depth[a] - depth[pa] - (depth[b] - depth[pb]));
  const lane = new Map(around.map(([key], k) => [key, k]));
  for (const [key, [from, to]] of links) {
    const [fx, fy, tx, ty] = [x[from], y(from), x[to], y(to)];
    const k = lane.get(key);
    if (k === undefined) {
      const [sx, sy] = towards(fx, fy, tx, ty, R);
      const [ex, ey] = towards(tx, ty, fx, fy, R + 2);
      svg += `<path data-tinyfly="uf-l-${key}" d="M${sx} ${sy} L${ex} ${ey}" fill="none" stroke="var(--muted)" stroke-width="2" marker-end="url(#uf-head)"/>`;
      continue;
    }
    // Left of every node from here up to the root.
    let left = fx;
    for (let v = from; v !== to; v = parent[v]) left = Math.min(left, x[v]);
    const laneX = left - R - 16 - 20 * k;
    const dy = 7 * (k + 1) - 4 * around.length;
    const ex = tx - Math.sqrt((R + 2) ** 2 - dy ** 2);
    svg += `<path data-tinyfly="uf-l-${key}" d="M${fx - R} ${fy} C${laneX} ${fy} ${laneX} ${ty + dy} ${ex} ${ty + dy}" fill="none" stroke="var(--muted)" stroke-width="2" marker-end="url(#uf-head)"/>`;
  }
  for (let v = 0; v < n; v++) {
    svg += `<circle data-tinyfly="uf-n-${v}" cx="${x[v]}" cy="${y(v)}" r="${R}" fill="var(--surface)" stroke="var(--muted)" stroke-width="2"/>`;
    svg += `<text data-tinyfly="uf-t-${v}" x="${x[v]}" y="${y(v)}" text-anchor="middle" dominant-baseline="central" font-size="14" fill="var(--text)">${v}</text>`;
  }

  const l = lesson({ id: name });
  for (const key of links.keys()) l.initial(`uf-l-${key}`, { opacity: 0 });
  for (let v = 0; v < n; v++) {
    l.initial(`uf-n-${v}`, { fill: "var(--surface)" });
    l.initial(`uf-t-${v}`, { fill: "var(--text)" });
  }
  l.marker("start", { label: `${n} nodes, and each node is its own root: ${n} groups.` });
  const mark = (nodes: number[], on: boolean) => {
    for (const v of nodes) {
      l.to(`uf-n-${v}`, { fill: on ? "var(--accent)" : "var(--surface)" }, { duration: 200 });
      l.to(`uf-t-${v}`, { fill: on ? "var(--on-accent)" : "var(--text)" }, { duration: 200 });
    }
  };
  let marked: number[] = [];
  for (const s of steps) {
    const now = [...new Set([s.ra, s.rb])];
    l.together(() => {
      mark(marked, false);
      mark(now, true);
      if (s.link) l.to(`uf-l-${s.link[0]}-${s.link[1]}`, { opacity: 1 }, { duration: 300 });
    });
    const label = s.link
      ? `Edge ${s.a}-${s.b}: the roots are ${s.ra} and ${s.rb}. ${s.link[0]} now points at ${s.link[1]}. ${s.groups} groups.`
      : `Edge ${s.a}-${s.b}: both roots are ${s.ra}. The two nodes are already in one group, and nothing changes.`;
    l.marker(`edge-${s.a}-${s.b}`, { label });
    l.wait(150);
    marked = now;
  }
  l.together(() => {
    mark(marked, false);
    mark(before, true);
  });
  l.marker("find", {
    label: `find(${before[0]}) walks ${before.join(" → ")}: ${before.length - 1} links to the root.`,
    pause: true,
    question: `Path compression points each node on the path straight at the root ${before[before.length - 1]}. Which parents change?`,
  });
  l.together(() => {
    for (const i of moved) {
      l.to(`uf-l-${i}-${parent[i]}`, { opacity: 0 }, { duration: 300 });
      l.to(`uf-l-${i}-${after[i]}`, { opacity: 1 }, { duration: 300 });
    }
  });
  l.marker("compressed", {
    label: `${moved.join(" and ")} now point at ${after[moved[0]]}. The next find(${before[0]}) walks 1 link.`,
  });
  l.together(() => mark(before, false));
  l.marker("done", { label: `${groups} groups at the end.` });

  return {
    markup: tokensToStyle(figure({ width, height, title: "Union-find: merges, then one compressing find", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `${n} nodes joined by ${steps.length} edges. An arrow from a node points at its parent. Then path compression points nodes ${moved.join(" and ")} at the root.`,
    caption: "The plain parent array from the program above, one edge for each step, then the compressing find on node 0.",
  };
}
