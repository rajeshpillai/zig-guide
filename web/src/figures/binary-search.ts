/**
 * The binary-search figures, built from the trace that
 * `23-competitive.binary-search` prints.
 *
 * The rows give `lo`, `mid` and `hi` at each step. Which branch ran is read
 * from the next row (or the closing line), not decided again here: a row that
 * matches neither branch throws, because then the trace and this file no
 * longer describe the same loop.
 */
import { cells, figure, lesson, pointer, type LessonBuilder } from "@algorisys/tinyfly/teach";
import { findSnippet, snippetSource } from "../snippets";
import { extractDecl } from "../source-quote";
import { THEME, block, check, esc, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.binary-search";

interface Step {
  lo: number;
  mid: number;
  hi: number;
}

interface Search {
  steps: Step[];
  /** The window after the last step. */
  end: { lo: number; hi: number };
  /** True when the trace ends on "no progress". */
  stalled: boolean;
}

const ROW = /^\s*step (\d+)\s+lo=\s*(\d+) mid=\s*(\d+) hi=\s*(\d+)/;

function parseSearch(lines: string[], name: string): Search {
  const steps: Step[] = [];
  let end: Search["end"] | null = null;
  let stalled = false;
  for (const line of lines) {
    const row = line.match(ROW);
    if (row) {
      check(Number(row[1]) === steps.length + 1, name, `step ${row[1]} is out of order`);
      steps.push({ lo: Number(row[2]), mid: Number(row[3]), hi: Number(row[4]) });
      continue;
    }
    const done = line.match(/window empty after (\d+) steps: lo = hi = (\d+)/);
    if (done) {
      check(Number(done[1]) === steps.length, name, "the step count in the closing line disagrees with the rows");
      end = { lo: Number(done[2]), hi: Number(done[2]) };
    }
    const stuck = line.match(/no progress: gave up at step (\d+) with lo=(\d+) hi=(\d+)/);
    if (stuck) {
      end = { lo: Number(stuck[2]), hi: Number(stuck[3]) };
      stalled = true;
    }
  }
  check(steps.length > 0 && end !== null, name, "no steps, or no closing line");
  return { steps, end, stalled };
}

function parseValues(output: string, name: string): number[] {
  const line = output.split("\n").find((l) => l.trim().startsWith("val "));
  check(line, name, "no `val` row in the output");
  return line.trim().split(/\s+/).slice(1).map(Number);
}

/** Which assignment turned this step's window into the next one. */
function branch(step: Step, next: { lo: number; hi: number }, name: string, i: number): "lo+1" | "lo" | "hi" {
  if (next.lo === step.mid + 1 && next.hi === step.hi) return "lo+1";
  if (next.hi === step.mid && next.lo === step.lo) return "hi";
  if (next.lo === step.mid && next.hi === step.hi) return "lo";
  throw new Error(`${name}: step ${i + 1} (lo=${step.lo} mid=${step.mid} hi=${step.hi}) does not lead to lo=${next.lo} hi=${next.hi} by any branch`);
}

const SIZE = 40;
const GAP = 6;
const X0 = 20;
const Y0 = 16;

/** Cells, three pointers and a status line, shared by both figures. */
function scene(values: number[], prefix: string, codeLines: string[] | null) {
  const row = cells({ id: `${prefix}-a`, values, x: X0, y: Y0, size: SIZE, gap: GAP, theme: THEME });
  const xAt = (index: number) => X0 + index * (SIZE + GAP) + SIZE / 2;
  const top = Y0 + SIZE + 30;
  const mid = pointer({ id: `${prefix}-mid`, label: "mid", x: xAt(0), y: top, theme: THEME });
  const lo = pointer({ id: `${prefix}-lo`, label: "lo", x: xAt(0), y: top + 52, theme: THEME });
  const hi = pointer({ id: `${prefix}-hi`, label: "hi", x: xAt(values.length), y: top + 104, theme: THEME });
  const width = X0 * 2 + (values.length + 1) * (SIZE + GAP);

  const lineHeight = 18;
  const codeTop = top + 160;
  const codeHeight = codeLines ? codeLines.length * lineHeight + 12 : 0;
  const pieces = [row, mid, lo, hi];
  if (codeLines) {
    const text = codeLines
      .map((line, i) => `<text x="${X0 + 8}" y="${codeTop + 6 + i * lineHeight + 13}" font-size="13" fill="var(--text)" xml:space="preserve">${esc(line)}</text>`)
      .join("");
    pieces.push(
      svgPiece(
        `<rect x="${X0}" y="${codeTop}" width="${width - 2 * X0}" height="${codeHeight}" rx="6" fill="var(--sunken)" stroke="var(--border)"/>` +
          `<rect data-tinyfly="${prefix}-line" x="${X0 + 2}" y="${codeTop + 6}" width="${width - 2 * X0 - 4}" height="${lineHeight}" fill="var(--accent)" opacity="0.18"/>` +
          text,
      ),
    );
  }
  // tinyfly moves an element along y by an offset from where the markup put
  // it, as it does for the pointers along x. The highlight starts on line 0.
  const lineY = (index: number) => index * lineHeight;
  return { row, mid, lo, hi, xAt, pieces, width, height: codeLines ? codeTop + codeHeight + 8 : codeTop - 4, lineY };
}

type Scene = ReturnType<typeof scene>;

/** Write one search into a lesson: a marker for the start, each step, and the end. */
function play(
  l: LessonBuilder,
  s: Scene,
  prefix: string,
  values: number[],
  key: number,
  search: Search,
  name: string,
  code: { at: (text: string) => number } | null,
  questionAt: number | null,
) {
  const n = values.length;
  const lineTarget = `${prefix}-line`;
  const window = (lo: number, hi: number) => {
    for (let i = 0; i < n; i++) {
      const inside = i >= lo && i < hi;
      l.to(s.row.cell(i), { opacity: inside ? 1 : 0.25 }, { duration: 300 });
      l.to(s.row.value(i), { opacity: inside ? 1 : 0.25 }, { duration: 300 });
    }
  };
  const highlightLine = (text: string) => {
    if (code) l.to(lineTarget, { y: s.lineY(code.at(text)) }, { duration: 250 });
  };

  l.initial(s.mid.name, { opacity: 0 });
  if (code) l.initial(lineTarget, { y: s.lineY(code.at("while (lo < hi)")) });
  l.marker("start", { label: `lo = 0 and hi = ${n}: all ${n} values are in the window.` });

  search.steps.forEach((step, i) => {
    const next = search.steps[i + 1] ?? search.end;
    const taken = branch(step, next, name, i);
    const value = values[step.mid];
    if (taken === "hi") check(!(value < key), name, `step ${i + 1} took hi = mid, but ${value} < ${key}`);
    else check(value < key, name, `step ${i + 1} moved lo, but ${value} is not less than ${key}`);

    l.together(() => {
      l.to(s.mid.name, { opacity: 1 }, { duration: 200 });
      s.mid.moveTo(l, s.xAt(step.mid), { duration: 350 });
      s.lo.moveTo(l, s.xAt(step.lo), { duration: 350 });
      s.hi.moveTo(l, s.xAt(step.hi), { duration: 350 });
      highlightLine("const mid");
    });
    if (questionAt === i + 1) {
      l.marker(`ask-${i + 1}`, {
        label: `Step ${i + 1}: items[${step.mid}] = ${value}.`,
        pause: true,
        question: `items[${step.mid}] is ${value}, and the key is ${key}. Which bound moves, and to which index?`,
      });
    }
    l.wait(300);

    const rule =
      taken === "hi"
        ? `${value} < ${key} is false, thus hi = mid = ${next.hi}.`
        : taken === "lo+1"
          ? `${value} < ${key} is true, thus lo = mid + 1 = ${next.lo}.`
          : `${value} < ${key} is true, thus lo = mid = ${next.lo}. The window did not change.`;
    l.together(() => {
      window(next.lo, next.hi);
      highlightLine("if (items[mid]");
      if (taken === "hi") s.hi.moveTo(l, s.xAt(next.hi), { duration: 350 });
      else s.lo.moveTo(l, s.xAt(next.lo), { duration: 350 });
    });
    l.marker(`step-${i + 1}`, { label: `Step ${i + 1}: ${rule}` });
    l.wait(200);
  });

  l.together(() => {
    l.to(s.mid.name, { opacity: 0 }, { duration: 200 });
    if (!search.stalled) highlightLine("return lo");
  });
  const last = search.stalled
    ? `The window stays at lo = ${search.end.lo}, hi = ${search.end.hi}. The loop never ends, and the program stops it after ${search.steps.length} steps.`
    : `lo = hi = ${search.end.lo}. The window is empty, and the answer is index ${search.end.lo}.`;
  l.marker(search.stalled ? "stuck" : "done", { label: last });
}

export async function binarySearchSteps(): Promise<Figure> {
  const name = "binary-search-steps";
  const output = await expectedOutput(SNIPPET);
  const values = parseValues(output, name);
  const heading = "lower bound of 7";
  const search = parseSearch(block(output, heading, name), name);

  const entry = await findSnippet(SNIPPET);
  const source = extractDecl(await snippetSource(entry), "lowerBound", entry.source, false, name);
  const codeLines = source.split("\n").filter((line) => !line.trimStart().startsWith("///"));
  const at = (text: string) => {
    const index = codeLines.findIndex((line) => line.includes(text));
    check(index !== -1, name, `lowerBound has no line containing "${text}"`);
    return index;
  };

  const s = scene(values, "bs", codeLines);
  const l = lesson({ id: name });
  play(l, s, "bs", values, 7, search, name, { at }, 2);

  return {
    markup: tokensToStyle(figure({ width: s.width, height: s.height, title: "lowerBound(7), one step at a time", children: s.pieces, theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: "Binary search for the lower bound of 7 in twelve sorted values, with lo, mid and hi pointers and the lowerBound source.",
    caption: "The trace of lowerBound(7) from the program above. Each step shows mid, the branch, and the window that is left.",
  };
}

export async function binarySearchStall(): Promise<Figure> {
  const name = "binary-search-stall";
  const output = await expectedOutput(SNIPPET);
  const values = parseValues(output, name);
  const good = parseSearch(block(output, "lower bound of 7", name), name);
  const bad = parseSearch(block(output, "the same search with lo = mid instead of lo = mid + 1", name), name);
  check(!good.stalled && bad.stalled, name, "expected one search that ends and one that stalls");

  const s = scene(values, "bx", null);
  const correct = lesson({ id: `${name}-plus-one` });
  play(correct, s, "bx", values, 7, good, name, null, null);
  const stalled = lesson({ id: `${name}-mid` });
  play(stalled, s, "bx", values, 7, bad, name, null, null);

  return {
    markup: tokensToStyle(figure({ width: s.width, height: s.height, title: "lo = mid + 1 against lo = mid", children: s.pieces, theme: THEME })),
    timelines: [
      { id: "plus-one", label: "lo = mid + 1", timeline: correct.definition() },
      { id: "mid", label: "lo = mid", timeline: stalled.definition() },
    ],
    legend: "Branch",
    alt: "The same binary search twice: with lo = mid + 1 it ends after four steps, and with lo = mid it repeats one window.",
    caption: "Select a branch. The steps have the same names in both, thus you can switch at any step and compare the two windows.",
  };
}
