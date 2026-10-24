/**
 * The monotonic-stack figure, built from the trace that
 * `23-competitive.monotonic-stack` prints: for each index, the entries it
 * resolved and the stack after it.
 *
 * The parser replays the pops and the push against the previous row's stack
 * and requires the result to equal the row's "stack after" column. That checks
 * that this file reads the trace the way the program wrote it.
 */
import { cells, figure, lesson, pointer, stack } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.monotonic-stack";

interface Row {
  i: number;
  value: number;
  /** Entries popped, in pop order (top first), with the answer each got. */
  resolved: Array<{ index: number; answer: number }>;
  /** The stack after this row, bottom to top, as "index:value". */
  after: string[];
}

function parse(lines: string[], name: string): Row[] {
  // The first line is the column header.
  const rows: Row[] = [];
  let stackNow: string[] = [];
  for (const line of lines.slice(1)) {
    const m = line.match(/^\s*(\d+)\s+(-?\d+)\s{2}(.+?)\s{2,}(\S.*)$/);
    if (!m) break;
    const i = Number(m[1]);
    const value = Number(m[2]);
    const resolvedText = m[3].trim();
    const resolved =
      resolvedText === "."
        ? []
        : resolvedText.split(",").map((part) => {
            const r = part.trim().match(/^(\d+) -> (-?\d+)$/);
            check(r, name, `cannot read "${part.trim()}" in row ${i}`);
            return { index: Number(r[1]), answer: Number(r[2]) };
          });
    const after = m[4].trim().split(/\s+/);

    for (const r of resolved) {
      const top = stackNow.pop();
      check(top?.startsWith(`${r.index}:`), name, `row ${i} pops ${r.index}, but the top of the stack is ${top}`);
      check(r.answer === value, name, `row ${i} gives ${r.index} the answer ${r.answer}, not ${value}`);
    }
    stackNow.push(`${i}:${value}`);
    check(stackNow.join(" ") === after.join(" "), name, `row ${i}: the replayed stack ${stackNow.join(" ")} is not ${after.join(" ")}`);
    rows.push({ i, value, resolved, after });
  }
  check(rows.length > 0 && rows.every((row, k) => row.i === k), name, "rows missing or out of order");
  return rows;
}

export async function monotonicStack(): Promise<Figure> {
  const name = "monotonic-stack";
  const output = await expectedOutput(SNIPPET);
  const rows = parse(block(output, "next greater to the right, one pass with a stack", name), name);
  const values = rows.map((row) => row.value);
  const capacity = Math.max(...rows.map((row) => row.after.length));

  const size = 40;
  const gap = 6;
  const x0 = 20;
  const input = cells({ id: "ms-in", values, x: x0, y: 30, size, gap, theme: THEME });
  const answers = cells({ id: "ms-ans", values: values.map(() => ""), x: x0, y: 180, size, gap, theme: THEME });
  const at = pointer({ id: "ms-i", label: "i", x: input.center(0).x, y: 96, theme: THEME });
  const rowWidth = values.length * (size + gap);
  const st = stack({ id: "ms-st", x: x0 + rowWidth + 30, y: 60, width: 150, frameHeight: 34, capacity, theme: THEME });
  const width = x0 + rowWidth + 30 + 150 + x0;
  const labels = svgPiece(
    `<text x="${x0}" y="20" font-size="13" fill="var(--muted)">input</text>` +
      `<text x="${x0}" y="170" font-size="13" fill="var(--muted)">next greater value</text>` +
      `<text x="${x0 + rowWidth + 30}" y="50" font-size="13" fill="var(--muted)">stack (index:value)</text>`,
  );

  // The two steps that ask the reader to predict: the first pop of more than
  // one entry, and the row with the most pops.
  const multi = rows.filter((row) => row.resolved.length > 1);
  check(multi.length > 0, name, "no row pops more than one entry, thus there is nothing to ask");
  const most = multi.reduce((a, b) => (b.resolved.length > a.resolved.length ? b : a));
  const ask = new Set([multi[0].i, most.i]);

  const l = lesson({ id: name });
  l.initial("ms-i", { opacity: 0 });
  l.marker("start", { label: "The stack is empty." });

  let before: string[] = [];
  for (const row of rows) {
    l.together(() => {
      l.to("ms-i", { opacity: 1 }, { duration: 150 });
      at.moveTo(l, input.center(row.i).x, { duration: 300 });
      if (row.i > 0) input.highlight(l, row.i - 1, "var(--surface)", { duration: 200 });
      input.highlight(l, row.i, "var(--raised)", { duration: 200 });
    });
    if (ask.has(row.i)) {
      const holds = before.length ? before.join(", ") : "nothing";
      l.marker(`ask-${row.i}`, {
        label: `i = ${row.i}: the value ${row.value} arrives.`,
        pause: true,
        question: `The stack holds ${holds}, bottom to top. Which entries does ${row.value} pop?`,
      });
    }
    for (const r of row.resolved) {
      st.pop(l, { duration: 250 });
      answers.write(l, r.index, r.answer, { duration: 250 });
    }
    st.push(l, `${row.i}:${row.value}`, { duration: 250 });
    const popped = row.resolved.length
      ? `pops ${row.resolved.map((r) => r.index).join(" and ")}, and each gets the answer ${row.value}`
      : "pops nothing";
    const text = `i = ${row.i}, value ${row.value}: ${popped}. Then it pushes ${row.i}:${row.value}.`;
    l.marker(`step-${row.i}`, { label: text });
    l.wait(150);
    before = row.after;
  }

  const left = before.join(" and ");
  const last = `The scan ends. ${left} stay on the stack: no larger value follows them.`;
  l.together(() => {
    l.to("ms-i", { opacity: 0 }, { duration: 200 });
    input.highlight(l, rows.length - 1, "var(--surface)", { duration: 200 });
  });
  l.marker("done", { label: last });

  return {
    markup: tokensToStyle(
      figure({ width, height: 240, title: "Next greater value with a stack", children: [input, answers, at, st, labels], theme: THEME }),
    ),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: "Eleven input values scanned left to right. Each value pops the smaller values from a stack and writes their next greater value.",
    caption: "The trace from the program above, one index for each step. Two steps stop and ask you to predict the pops.",
  };
}
