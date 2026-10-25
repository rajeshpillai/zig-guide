/**
 * Figures for the range chapters of Competitive Programming: the difference
 * array (Prefix Sums), the merge pass (Merge Intervals) and the window
 * maximum (Monotonic Deque). Each is built from its snippet's printed trace.
 */
import { cells, figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const nums = (text: string) => text.trim().split(/\s+/).map(Number);

/* ------------------------------------------------------------------ */
/* Prefix Sums: range updates on a difference array                     */
/* ------------------------------------------------------------------ */

export async function differenceArray(): Promise<Figure> {
  const name = "difference-array";
  const output = await expectedOutput("23-competitive.prefix-sums");
  const rows = block(output, "3 range updates on a difference array", name);
  const updates: Array<{ label: string; value: number; lo: number; hi: number; cells: number[] }> = [];
  let marks: number[] | null = null;
  for (const line of rows.slice(1)) {
    const start = line.match(/^\s*start\s+(.*)$/);
    if (start) {
      marks = nums(start[1]);
      continue;
    }
    const m = line.match(/^\s*([+-]\d+) on \[(\d+),(\d+)\)\s+(.*)$/);
    if (m) updates.push({ label: `${m[1]} on [${m[2]},${m[3]})`, value: Number(m[1]), lo: Number(m[2]), hi: Number(m[3]), cells: nums(m[4]) });
  }
  check(marks && updates.length > 0, name, "no start row or no updates");
  // Each update changes exactly two cells: +v at lo, -v at hi.
  let before = marks;
  for (const u of updates) {
    const changed = u.cells.map((v, i) => v - before[i]).map((d, i) => (d !== 0 ? i : -1)).filter((i) => i >= 0);
    check(changed.join(",") === [u.lo, u.hi].join(","), name, `${u.label} changed cells ${changed.join(", ")}, not ${u.lo} and ${u.hi}`);
    check(u.cells[u.lo] - before[u.lo] === u.value && u.cells[u.hi] - before[u.hi] === -u.value, name, `${u.label} did not add ${u.value} and ${-u.value}`);
    before = u.cells;
  }
  const totLine = block(output, "one running sum turns those marks into values", name).find((l) => l.trim().startsWith("tot "));
  check(totLine, name, "no tot row");
  const totals = nums(totLine.trim().slice(3));
  let run = 0;
  totals.forEach((t, i) => {
    run += before[i];
    check(run === t, name, `the running sum at ${i} is ${run}, not the printed ${t}`);
  });

  const size = 44;
  const gap = 6;
  const x0 = 70;
  const diff = cells({ id: "da", values: marks, x: x0, y: 34, size, gap, theme: THEME });
  const tot = cells({ id: "dt", values: totals.map(() => ""), x: x0, y: 130, size, gap, theme: THEME });
  const labels = svgPiece(
    `<text x="10" y="${34 + size / 2}" dominant-baseline="central" font-size="12" fill="var(--muted)">marks</text>` +
      `<text x="10" y="${130 + size / 2}" dominant-baseline="central" font-size="12" fill="var(--muted)">values</text>`,
  );

  const l = lesson({ id: name });
  l.marker("start", { label: `${marks.length} marks, all 0. The array has one cell more than the ${totals.length} values.` });
  let shown = marks;
  updates.forEach((u, k) => {
    l.together(() => {
      for (const i of [u.lo, u.hi]) {
        diff.write(l, i, u.cells[i], { duration: 250 });
        diff.highlight(l, i, "var(--raised)", { duration: 250 });
      }
    });
    l.marker(`update-${k + 1}`, {
      label: `${u.label}: add ${u.value} at ${u.lo}, and ${-u.value} at ${u.hi}, where the range ends. Two writes, whatever the length of the range.`,
    });
    l.wait(150);
    shown = u.cells;
  });
  l.marker("ask", {
    label: "Now one running sum, from left to right, turns the marks into values.",
    pause: true,
    question: `The marks start ${shown.slice(0, 4).join(", ")}. What is the running sum at index 3?`,
  });
  let sum = 0;
  totals.forEach((t, i) => {
    sum += shown[i];
    tot.write(l, i, t, { duration: 200 });
    l.marker(`sum-${i}`, { label: `Index ${i}: the running sum adds ${shown[i]} and is ${t}.` });
    l.wait(100);
  });
  l.marker("done", { label: `${updates.length} updates cost ${updates.length * 2} writes and one pass. The values are the same as the slow way, which writes each cell of each range.` });

  return {
    markup: tokensToStyle(figure({ width: x0 + marks.length * (size + gap) + 20, height: 200, title: "Range updates on a difference array", children: [diff, tot, labels], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `A difference array of ${marks.length} marks. ${updates.length} range updates each write two marks, and a running sum turns the marks into ${totals.length} values.`,
    caption: "The updates and the running sum from the program above. The figure stops before the sum and asks you to predict one value.",
  };
}

/* ------------------------------------------------------------------ */
/* Merge Intervals: the larger end against the next end                */
/* ------------------------------------------------------------------ */

interface MergeRow {
  start: number;
  end: number;
  action: string;
  run: [number, number];
}

function mergeRows(lines: string[], name: string): MergeRow[] {
  const rows: MergeRow[] = [];
  for (const line of lines.slice(1)) {
    const m = line.match(/^\s*\[\s*(\d+),\s*(\d+)\]\s+(?:first|\d+ <=?\s+\d+|\d+ >\s+\d+)\s+(\w+)\s+\[\s*(\d+),\s*(\d+)\]$/);
    if (m) rows.push({ start: Number(m[1]), end: Number(m[2]), action: m[3], run: [Number(m[4]), Number(m[5])] });
  }
  check(rows.length > 0, name, "no merge rows");
  return rows;
}

export async function mergeIntervals(): Promise<Figure> {
  const name = "merge-intervals";
  const output = await expectedOutput("23-competitive.merge-intervals");
  const good = mergeRows(block(output, "one pass, each interval against the run being built", name), name);
  const bad = mergeRows(block(output, "the same pass with end = next end, in place of the larger end", name), name);
  check(good.length === bad.length && good.every((r, k) => r.start === bad[k].start && r.end === bad[k].end), name, "the two passes read different intervals");
  // A run is "opened" by its first interval and then only grows, so each
  // row's run belongs to the run opened last. Count them per pass.
  const runsOf = (rows: MergeRow[]) => {
    const runs: number[] = [];
    rows.forEach((r, k) => {
      if (r.action === "opened") runs.push(k);
      check(runs.length > 0, name, "a row before the first opened run");
    });
    return runs.length;
  };
  const maxRuns = Math.max(runsOf(good), runsOf(bad));
  const dropped = output.match(/end = next drops: ([\d ]+)/)?.[1].trim();
  check(dropped, name, "no line naming the coordinates that end = next drops");
  const span = Math.max(...good.map((r) => r.end)) + 2;

  const unit = 15;
  const x0 = 20;
  const lane = 14;
  const top = 30;
  const xAt = (c: number) => x0 + c * unit;
  const runY = top + good.length * lane + 30;
  let svg = `<text x="${x0}" y="${top - 12}" font-size="12" fill="var(--muted)">intervals, sorted by start</text>`;
  good.forEach((r, k) => {
    svg += `<rect data-tinyfly="mi-i-${k}" x="${xAt(r.start)}" y="${top + k * lane}" width="${Math.max((r.end - r.start) * unit, 4)}" height="${lane - 4}" rx="3" fill="var(--muted)" style="opacity:0.35"/>`;
  });
  svg += `<text x="${x0}" y="${runY - 10}" font-size="12" fill="var(--muted)">runs</text>`;
  for (let k = 0; k < maxRuns; k++) {
    svg += `<rect data-tinyfly="mi-r-${k}" x="${xAt(0)}" y="${runY}" width="4" height="18" rx="4" fill="var(--accent)" style="opacity:0"/>`;
  }
  for (let c = 0; c <= span; c += 5) {
    svg += `<text x="${xAt(c)}" y="${runY + 40}" text-anchor="middle" font-size="11" fill="var(--muted)">${c}</text>`;
    svg += `<line x1="${xAt(c)}" y1="${runY + 24}" x2="${xAt(c)}" y2="${runY + 29}" stroke="var(--muted)"/>`;
  }

  const play = (id: string, rows: MergeRow[], closing: string) => {
    const l = lesson({ id });
    // Every part either pass moves gets a start state in both (see TraceFigure).
    rows.forEach((_, k) => {
      l.initial(`mi-i-${k}`, { opacity: 0.35 });
      l.set(`mi-i-${k}`, { opacity: 0.35 });
    });
    for (let k = 0; k < maxRuns; k++) {
      l.initial(`mi-r-${k}`, { opacity: 0, x: 0, width: 4 });
      l.set(`mi-r-${k}`, { opacity: 0, x: 0, width: 4 });
    }
    l.marker("start", { label: "The intervals are sorted by start. The pass reads them from the top." });
    let current = -1;
    rows.forEach((r, k) => {
      if (r.action === "opened") current += 1;
      l.together(() => {
        if (k > 0) l.to(`mi-i-${k - 1}`, { opacity: 0.35 }, { duration: 150 });
        l.to(`mi-i-${k}`, { opacity: 1 }, { duration: 200 });
        l.to(`mi-r-${current}`, { opacity: 1, x: xAt(r.run[0]) - xAt(0), width: Math.max((r.run[1] - r.run[0]) * unit, 4) }, { duration: 300 });
      });
      const what =
        r.action === "opened"
          ? `opens a new run [${r.run[0]}, ${r.run[1]}]`
          : r.action === "covered"
            ? `is inside the run, which stays [${r.run[0]}, ${r.run[1]}]`
            : r.action === "extended"
              ? `extends the run to [${r.run[0]}, ${r.run[1]}]`
              : `makes the run shorter: [${r.run[0]}, ${r.run[1]}]`;
      l.marker(`row-${k + 1}`, { label: `[${r.start}, ${r.end}] ${what}.` });
      l.wait(120);
    });
    l.to(`mi-i-${rows.length - 1}`, { opacity: 0.35 }, { duration: 150 });
    l.marker("end", { label: closing });
    return l.definition();
  };

  const runsText = (rows: MergeRow[]) =>
    rows.filter((_, k) => k === rows.length - 1 || rows[k + 1].action === "opened").map((r) => `[${r.run[0]}, ${r.run[1]}]`).join(" ");
  return {
    markup: tokensToStyle(figure({ width: xAt(span) + 30, height: runY + 50, title: "Merging intervals in one pass", children: [svgPiece(svg)], theme: THEME })),
    timelines: [
      { id: "larger", label: "end = larger end", timeline: play("larger", good, `${runsOf(good)} runs: ${runsText(good)}.`) },
      { id: "next", label: "end = next end", timeline: play("next", bad, `${runsOf(bad)} runs: ${runsText(bad)}. The input covers coordinates ${dropped.split(" ").join(", ")}, and no run does.`) },
    ],
    legend: "Rule",
    alt: `${good.length} sorted intervals on a number line, merged into runs. With the larger end there are ${runsOf(good)} runs; with the next end there are ${runsOf(bad)}.`,
    caption: "The two passes from the program above. Select a rule and step through the intervals. The steps have the same names, thus you can switch at any step.",
  };
}

/* ------------------------------------------------------------------ */
/* Monotonic Deque: the maximum of each window                         */
/* ------------------------------------------------------------------ */

export async function windowMaximum(): Promise<Figure> {
  const name = "window-maximum";
  const output = await expectedOutput("23-competitive.monotonic-deque");
  const width = Number(output.match(/window width (\d+)/)?.[1]);
  const values = nums(output.split("\n").find((l) => l.trim().startsWith("val "))!.trim().slice(3));
  const rows = block(output, "the deque, one row per arriving value", name)
    .slice(1)
    .map((line) => line.match(/^\s*(\d+)\s+(-?\d+)\s{2}(.+?)\s{2,}(\S+(?:, \S+)*|\.)\s{2,}((?:\d+:-?\d+ ?)+)\s+(\.|\d+)$/))
    .filter((m): m is RegExpMatchArray => m !== null)
    .map((m) => ({
      i: Number(m[1]),
      value: Number(m[2]),
      evicted: m[3].trim() === "." ? [] : m[3].trim().split(", "),
      expired: m[4].trim() === "." ? [] : m[4].trim().split(", "),
      deque: m[5].trim().split(" "),
      max: m[6] === "." ? null : Number(m[6]),
    }));
  check(rows.length === values.length, name, `read ${rows.length} rows for ${values.length} values`);
  // Replay: expire from the front, evict from the back, push; then the front
  // is the maximum once the window is full.
  let deque: string[] = [];
  for (const r of rows) {
    for (const e of r.expired) check(deque.shift() === e, name, `i=${r.i}: ${e} is not at the front`);
    for (const e of r.evicted) check(deque.pop() === e, name, `i=${r.i}: ${e} is not at the back`);
    deque.push(`${r.i}:${r.value}`);
    check(deque.join(" ") === r.deque.join(" "), name, `i=${r.i}: the replayed deque ${deque.join(" ")} is not ${r.deque.join(" ")}`);
    if (r.i >= width - 1) check(r.max === Number(deque[0].split(":")[1]), name, `i=${r.i}: the maximum is not the front`);
  }
  const capacity = Math.max(...rows.map((r) => r.deque.length));

  const size = 40;
  const gap = 6;
  const x0 = 20;
  const input = cells({ id: "wm", values, x: x0, y: 30, size, gap, theme: THEME });
  const left = (i: number) => x0 + i * (size + gap) - 4;
  const frame = `<rect data-tinyfly="wm-win" x="${left(0)}" y="24" width="${(size + gap) * width + 2}" height="${size + 12}" rx="8" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;
  const dqY = 128;
  let slots = `<text x="${x0}" y="${dqY - 10}" font-size="12" fill="var(--muted)">deque (index:value), front on the left</text>`;
  for (let k = 0; k < capacity; k++) {
    const x = x0 + k * 74;
    slots += `<rect data-tinyfly="wm-s-${k}" x="${x}" y="${dqY}" width="68" height="34" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="2" style="opacity:0"/>`;
    slots += `<text data-tinyfly="wm-t-${k}" x="${x + 34}" y="${dqY + 17}" text-anchor="middle" dominant-baseline="central" font-size="14" fill="var(--text)"></text>`;
  }
  slots += `<text data-tinyfly="wm-max" x="${x0 + capacity * 74 + 20}" y="${dqY + 17}" dominant-baseline="central" font-size="15" fill="var(--text)"></text>`;

  const l = lesson({ id: name });
  l.initial("wm-win", { opacity: 0, x: 0 });
  for (let k = 0; k < capacity; k++) l.initial(`wm-s-${k}`, { opacity: 0 });
  l.marker("start", { label: `${values.length} values, a window of ${width}. The deque keeps indices whose values fall from front to back.` });
  for (const r of rows) {
    const start = Math.max(0, r.i - width + 1);
    l.together(() => {
      l.to("wm-win", { opacity: r.i >= width - 1 ? 1 : 0.4, x: left(start) - left(0) }, { duration: 250 });
      for (let k = 0; k < capacity; k++) {
        l.to(`wm-s-${k}`, { opacity: k < r.deque.length ? 1 : 0 }, { duration: 200 });
        l.set(`wm-t-${k}`, { text: r.deque[k] ?? "" });
      }
      l.set("wm-max", { text: r.max === null ? "" : `max ${r.max}` });
    });
    const parts = [`i = ${r.i}, value ${r.value}.`];
    if (r.expired.length) parts.push(`${r.expired.join(" and ")} left the front: its index is below the window start ${start}.`);
    if (r.evicted.length) parts.push(`${r.evicted.join(", ")} left the back: smaller than ${r.value}, and older.`);
    parts.push(r.max === null ? "The window is not full yet." : `The front holds the maximum, ${r.max}.`);
    l.marker(`i-${r.i}`, { label: parts.join(" ") });
    l.wait(120);
  }
  l.marker("done", { label: `Each index entered the deque once and left it at most once: ${rows.length} pushes for ${rows.length} values.` });

  return {
    markup: tokensToStyle(figure({ width: Math.max(x0 + values.length * (size + gap) + 20, x0 + capacity * 74 + 120), height: dqY + 50, title: "The maximum of each window, with a deque", children: [input, svgPiece(frame + slots)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `${values.length} values and a window of ${width} that moves right. A deque under them keeps the candidates for the maximum, and its front is the answer.`,
    caption: "The deque trace from the program above, one step for each new value.",
  };
}
