/**
 * The container-with-most-water figure, built from the trace that
 * `23-competitive.two-pointers` prints.
 *
 * The trace prints `h[lo]` and `h[hi]` at each step, not the input row. The
 * two pointers visit every index between them, so the rows give every wall
 * height; the parser requires that, and that an index never reports two
 * different heights. It also requires each row's width, area and best to
 * follow from the row, and each "moved" to name the lower wall.
 */
import { figure, lesson, pointer } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.two-pointers";

interface Row {
  step: number;
  lo: number;
  hi: number;
  width: number;
  area: number;
  best: number;
  moved: "lo" | "hi";
}

function parse(lines: string[], name: string) {
  const rows: Row[] = [];
  const heights = new Map<number, number>();
  const learn = (index: number, h: number) => {
    const known = heights.get(index);
    check(known === undefined || known === h, name, `index ${index} has height ${known} and ${h}`);
    heights.set(index, h);
  };
  for (const line of lines.slice(1)) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(lo|hi)$/);
    if (!m) continue;
    const [step, lo, hi, hlo, hhi, width, area, best] = m.slice(1, 9).map(Number);
    learn(lo, hlo);
    learn(hi, hhi);
    check(width === hi - lo, name, `step ${step}: width ${width} is not hi - lo`);
    check(area === Math.min(hlo, hhi) * width, name, `step ${step}: area ${area} is not the lower wall times the width`);
    const lower = hlo < hhi ? "lo" : "hi";
    check(m[9] === lower || hlo === hhi, name, `step ${step} moved ${m[9]}, not the lower wall`);
    rows.push({ step, lo, hi, width, area, best, moved: m[9] as "lo" | "hi" });
  }
  check(rows.length > 0, name, "no rows");
  const done = lines.join("\n").match(/best (\d+) between index (\d+) and index (\d+)/);
  check(done, name, "no closing line");
  const n = rows[0].hi + 1;
  for (let i = 0; i < n; i++) check(heights.has(i), name, `no row reports the height of index ${i}`);
  return { rows, heights: Array.from({ length: n }, (_, i) => heights.get(i)!), best: { area: Number(done[1]), lo: Number(done[2]), hi: Number(done[3]) } };
}

export async function containerWater(): Promise<Figure> {
  const name = "container-water";
  const output = await expectedOutput(SNIPPET);
  const { rows, heights, best } = parse(block(output, "most water between two walls", name), name);

  const unit = 20;
  const barW = 30;
  const gap = 16;
  const x0 = 30;
  const top = 20;
  const maxH = Math.max(...heights);
  const floor = top + maxH * unit;
  const cx = (i: number) => x0 + i * (barW + gap) + barW / 2;
  const width = x0 * 2 + heights.length * (barW + gap);

  // One water area for each step, drawn now and shown in turn: the area of a
  // step is the rectangle between the two walls, as high as the lower one.
  const water = rows
    .map((row) => {
      const h = Math.min(heights[row.lo], heights[row.hi]) * unit;
      return `<rect data-tinyfly="cw-water-${row.step}" x="${cx(row.lo)}" y="${floor - h}" width="${cx(row.hi) - cx(row.lo)}" height="${h}" fill="var(--accent)" style="opacity:0" fill-opacity="0.22"/>`;
    })
    .join("");
  const bh = Math.min(heights[best.lo], heights[best.hi]) * unit;
  const bestOutline = `<rect data-tinyfly="cw-best" x="${cx(best.lo)}" y="${floor - bh}" width="${cx(best.hi) - cx(best.lo)}" height="${bh}" fill="none" stroke="var(--accent)" stroke-width="2" stroke-dasharray="6 4" style="opacity:0"/>`;
  const bars = heights
    .map(
      (h, i) =>
        `<rect x="${x0 + i * (barW + gap)}" y="${floor - h * unit}" width="${barW}" height="${h * unit}" rx="3" fill="var(--muted)"/>` +
        `<text x="${cx(i)}" y="${floor - h * unit - 6}" text-anchor="middle" font-size="12" fill="var(--text)">${h}</text>` +
        `<text x="${cx(i)}" y="${floor + 16}" text-anchor="middle" font-size="12" fill="var(--muted)">${i}</text>`,
    )
    .join("");
  const ground = `<line x1="${x0 - 10}" y1="${floor}" x2="${width - x0 + 10}" y2="${floor}" stroke="var(--muted)" stroke-width="2"/>`;

  const lo = pointer({ id: "cw-lo", label: "lo", x: cx(0), y: floor + 24, theme: THEME });
  const hi = pointer({ id: "cw-hi", label: "hi", x: cx(heights.length - 1), y: floor + 24, theme: THEME });

  const l = lesson({ id: name });
  // A track starts from the property's default (opacity 1), not from the
  // markup's style, so each hidden part says it starts hidden.
  for (const row of rows) l.initial(`cw-water-${row.step}`, { opacity: 0 });
  l.initial("cw-best", { opacity: 0 });
  l.marker("start", { label: `lo starts at the first wall and hi at the last. The width is ${heights.length - 1}, the largest possible.` });
  let prev: number | null = null;
  let bestSoFar = 0;
  for (const row of rows) {
    const newBest = row.best > bestSoFar;
    l.together(() => {
      lo.moveTo(l, cx(row.lo), { duration: 350 });
      hi.moveTo(l, cx(row.hi), { duration: 350 });
      if (prev !== null) l.to(`cw-water-${prev}`, { opacity: 0 }, { duration: 250 });
      l.to(`cw-water-${row.step}`, { opacity: 1 }, { duration: 350 });
      if (newBest && row.best === best.area) l.to("cw-best", { opacity: 1 }, { duration: 350 });
    });
    const lower = Math.min(heights[row.lo], heights[row.hi]);
    const record = newBest ? " That is a new best." : ` The best is still ${row.best}.`;
    const move =
      heights[row.lo] === heights[row.hi]
        ? `The two walls are equal, and the program moves ${row.moved}.`
        : `Move ${row.moved}, the lower wall.`;
    l.marker(`step-${row.step}`, {
      label: `Step ${row.step}: width ${row.width} times the lower wall ${lower} is ${row.area}.${record} ${move}`,
    });
    bestSoFar = row.best;
    l.wait(200);
    prev = row.step;
  }
  l.to(`cw-water-${prev}`, { opacity: 0 }, { duration: 250 });
  const last = `lo and hi meet. The best area is ${best.area}, between index ${best.lo} and index ${best.hi}.`;
  l.marker("done", { label: last });

  return {
    markup: tokensToStyle(
      figure({ width, height: floor + 76, title: "Most water between two walls", children: [svgPiece(water + bestOutline + bars + ground), lo, hi], theme: THEME }),
    ),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `Nine walls of heights ${heights.join(", ")}. The water between lo and hi is drawn at each step, and a dashed outline marks the best area.`,
    caption: "The trace from the program above. At each step, the shaded area is the water between the two walls, and the lower wall moves.",
  };
}
