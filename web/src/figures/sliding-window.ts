/**
 * The shortest-run figure, built from the trace that
 * `23-competitive.sliding-window` prints for "shortest run of values summing
 * to 19 or more".
 *
 * Each row shows the window as brackets around some of the values. The parser
 * reads the bracket positions, requires the bracketed values to add up to the
 * row's sum and the bracket width to equal the row's length, and requires the
 * shortest window of a `shrink` row (a row whose window reached the target)
 * to be the answer the program prints.
 */
import { cells, figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.sliding-window";

interface Row {
  move: "grow" | "shrink";
  value: number;
  sum: number;
  start: number;
  end: number;
}

function parse(lines: string[], name: string) {
  const rows: Row[] = [];
  let values: number[] | null = null;
  for (const line of lines.slice(1)) {
    const m = line.match(/^\s*(grow|shrink)\s+(-?\d+)\s+(-?\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    const tokens = m[5].replace(/\[/g, " [ ").replace(/\]/g, " ] ").trim().split(/\s+/);
    const cellsHere: number[] = [];
    let start = -1;
    let end = -1;
    for (const token of tokens) {
      if (token === "[") start = cellsHere.length;
      else if (token === "]") end = cellsHere.length;
      else cellsHere.push(Number(token));
    }
    check(start >= 0 && end > start, name, `no window in "${line.trim()}"`);
    if (values === null) values = cellsHere;
    check(values.join(" ") === cellsHere.join(" "), name, "the values differ between rows");
    const sum = Number(m[3]);
    const inside = cellsHere.slice(start, end).reduce((a, b) => a + b, 0);
    check(inside === sum, name, `the window ${start}..${end} adds up to ${inside}, not ${sum}`);
    check(end - start === Number(m[4]), name, `the window ${start}..${end} is not ${m[4]} values long`);
    rows.push({ move: m[1] as Row["move"], value: Number(m[2]), sum, start, end });
  }
  check(values !== null && rows.length > 0, name, "no rows");
  const answer = lines.join("\n").match(/answer: items\[(\d+)\.\.(\d+)\], (\d+) values summing to (\d+)/);
  check(answer, name, "no answer line");
  const target = Number(lines[0].match(/summing to (\d+) or more/)?.[1] ?? NaN);
  const valid = rows.filter((row) => row.move === "shrink");
  const shortest = valid.reduce((a, b) => (b.end - b.start < a.end - a.start ? b : a));
  check(
    shortest.start === Number(answer[1]) && shortest.end === Number(answer[2]),
    name,
    `the shortest valid window is ${shortest.start}..${shortest.end}, but the answer line says ${answer[1]}..${answer[2]}`,
  );
  return { rows, values, shortest };
}

export async function shortestRun(): Promise<Figure> {
  const name = "shortest-run";
  const output = await expectedOutput(SNIPPET);
  const heading = "shortest run of values summing to 19 or more";
  const { rows, values, shortest } = parse([heading, ...block(output, heading, name)], name);

  const size = 44;
  const gap = 6;
  const x0 = 20;
  const y0 = 40;
  const row = cells({ id: "sw", values, x: x0, y: y0, size, gap, theme: THEME });
  const left = (i: number) => x0 + i * (size + gap) - 4;
  const width = x0 * 2 + values.length * (size + gap);
  // The window is one outline. It moves along x and changes its width, which
  // tinyfly animates as an attribute; its x moves as an offset from index 0.
  const frame = `<rect data-tinyfly="sw-window" x="${left(0)}" y="${y0 - 6}" width="${size + 8}" height="${size + 12}" rx="8" fill="none" stroke="var(--accent)" stroke-width="3"/>`;
  const answer = `<rect data-tinyfly="sw-answer" x="${left(shortest.start)}" y="${y0 - 6}" width="${(shortest.end - shortest.start) * (size + gap) + 2}" height="${size + 12}" rx="8" fill="none" stroke="var(--accent)" stroke-width="2" stroke-dasharray="6 4" style="opacity:0"/>`;
  const labels = `<text x="${x0}" y="20" font-size="13" fill="var(--muted)">target: a sum of 19 or more, with the fewest values</text>`;

  const l = lesson({ id: name });
  const show = (r: Row) => {
    l.to("sw-window", { x: left(r.start) - left(0), width: (r.end - r.start) * (size + gap) + 2 }, { duration: 300 });
  };
  l.initial("sw-window", { opacity: 0 });
  l.initial("sw-answer", { opacity: 0 });
  l.marker("start", { label: "The window is empty. The right edge moves first." });
  let best: Row | null = null;
  rows.forEach((r, k) => {
    l.together(() => {
      l.to("sw-window", { opacity: 1 }, { duration: 150 });
      show(r);
    });
    const length = r.end - r.start;
    let label: string;
    if (r.move === "grow") {
      label = `Grow: add ${r.value}. The sum is ${r.sum} with ${length} values${r.sum >= 19 ? "." : ", less than 19."}`;
    } else {
      const shorter = best === null || length < best.end - best.start;
      if (shorter) best = r;
      label = `The sum ${r.sum} gets to 19 with ${length} values${shorter ? ", the shortest so far" : ""}. Next, remove ${r.value} from the left.`;
    }
    l.marker(`move-${k + 1}`, { label });
    l.wait(150);
  });
  l.together(() => {
    l.to("sw-window", { opacity: 0 }, { duration: 200 });
    l.to("sw-answer", { opacity: 1 }, { duration: 300 });
  });
  l.marker("done", {
    label: `The right edge is at the end. The shortest window is items[${shortest.start}..${shortest.end}]: ${values.slice(shortest.start, shortest.end).join(" + ")} = ${shortest.sum}.`,
  });

  return {
    markup: tokensToStyle(
      figure({ width, height: y0 + size + 40, title: "The shortest run with a sum of 19 or more", children: [row, svgPiece(labels + frame + answer)], theme: THEME }),
    ),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `Ten values, ${values.join(", ")}, with an outline for the window. The outline grows to the right and shrinks from the left.`,
    caption: "The trace from the program above, one row for each step. The outline is the window, and the dashed outline at the end is the answer.",
  };
}
