/**
 * The knapsack figures, built from what `23-competitive.knapsack` prints: the
 * full `dp` table, the walk back from its last cell, and the one-row version
 * with the capacity loop in both directions.
 *
 * The parser requires the walk to read the table's own cells (each "dp[i][c]"
 * and "above" value must be the cell the table holds), each skip to be a cell
 * equal to the one above it, and the downward one-row version to end on the
 * table's last row. A trace that disagrees with itself fails the build.
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, esc, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.knapsack";

interface Item {
  weight: number;
  value: number;
}

/** Rows of the form `+ w5 v10   0 0 0 ...`, after a header of capacities. */
function parseRows(lines: string[], name: string) {
  const rows: Array<{ item: Item; cells: number[] }> = [];
  let base: number[] | null = null;
  for (const line of lines.slice(1)) {
    const none = line.match(/^\s*none\s+(.*)$/);
    if (none) {
      base = none[1].trim().split(/\s+/).map(Number);
      continue;
    }
    const m = line.match(/^\s*\+ w(\d+) v(\d+)\s+(.*)$/);
    if (!m) continue;
    rows.push({ item: { weight: Number(m[1]), value: Number(m[2]) }, cells: m[3].trim().split(/\s+/).map(Number) });
  }
  check(rows.length > 0, name, "no item rows");
  return { base, rows };
}

const CELL_W = 44;
const CELL_H = 30;
const LABEL_W = 96;
const X0 = 16;
const Y0 = 46;

/** A grid of value cells. Each cell's text has a name, so a step can write it. */
function grid(prefix: string, labels: string[], columns: number) {
  let svg = "";
  for (let c = 0; c < columns; c++) {
    svg += `<text x="${X0 + LABEL_W + c * CELL_W + CELL_W / 2}" y="${Y0 - 10}" text-anchor="middle" font-size="12" fill="var(--muted)">${c}</text>`;
  }
  labels.forEach((label, r) => {
    const y = Y0 + r * CELL_H;
    svg += `<text x="${X0}" y="${y + CELL_H / 2}" dominant-baseline="central" font-size="12" fill="var(--muted)">${esc(label)}</text>`;
    for (let c = 0; c < columns; c++) {
      const x = X0 + LABEL_W + c * CELL_W;
      svg += `<rect data-tinyfly="${prefix}-${r}-${c}" x="${x}" y="${y}" width="${CELL_W - 2}" height="${CELL_H - 2}" rx="3" fill="var(--sunken)" stroke="var(--accent)" stroke-width="0"/>`;
      svg += `<text data-tinyfly="${prefix}-t-${r}-${c}" x="${x + (CELL_W - 2) / 2}" y="${y + (CELL_H - 2) / 2}" text-anchor="middle" dominant-baseline="central" font-size="13" fill="var(--text)"></text>`;
    }
  });
  const width = X0 * 2 + LABEL_W + columns * CELL_W;
  const height = Y0 + labels.length * CELL_H + 12;
  return { svg: `<text x="${X0 + LABEL_W}" y="12" font-size="12" fill="var(--muted)">room in the bag</text>` + svg, width, height };
}

export async function knapsackTable(): Promise<Figure> {
  const name = "knapsack-table";
  const output = await expectedOutput(SNIPPET);
  const table = parseRows(block(output, "dp[i][c]: best value from the first i items with room c", name), name);
  check(table.base, name, "no `none` row");
  const rows = [table.base, ...table.rows.map((r) => r.cells)];
  const cap = rows[0].length - 1;

  const walk = block(output, "walking back from the bottom-right cell", name)
    .map((line) => line.match(/item (\d+) \(w(\d+) v(\d+)\)\s+dp\[(\d+)\]\[\s*(\d+)\] =\s*(\d+), above\s+(\d+)\s+-> (take|skip)/))
    .filter((m): m is RegExpMatchArray => m !== null)
    .map((m) => ({ item: Number(m[1]), i: Number(m[4]), c: Number(m[5]), here: Number(m[6]), above: Number(m[7]), take: m[8] === "take" }));
  check(walk.length === table.rows.length, name, "the walk back does not visit each item once");
  let room = cap;
  for (const step of walk) {
    check(step.c === room, name, `item ${step.item}: the walk reads column ${step.c}, but the room is ${room}`);
    check(rows[step.i][step.c] === step.here && rows[step.i - 1][step.c] === step.above, name, `item ${step.item}: the walk does not read the table's cells`);
    check(step.take === (step.here !== step.above), name, `item ${step.item}: take or skip does not follow from the two cells`);
    if (step.take) room -= table.rows[step.i - 1].item.weight;
  }

  const labels = ["none", ...table.rows.map((r) => `+ w${r.item.weight} v${r.item.value}`)];
  const g = grid("kt", labels, cap + 1);
  const l = lesson({ id: name });
  // Every colour that changes gets a start value. Without one, a track's
  // first keyframe is not the markup's colour, and the walk's cells showed
  // their final colours before the walk reached them.
  rows.forEach((cells, r) =>
    cells.forEach((_, c) => {
      l.initial(`kt-${r}-${c}`, { fill: "var(--sunken)", strokeWidth: 0 });
      l.initial(`kt-t-${r}-${c}`, { fill: "var(--text)" });
    }),
  );
  l.marker("start", { label: "Each row adds one item. Each cell is the best value with that much room." });

  rows.forEach((cells, r) => {
    l.together(() => {
      cells.forEach((value, c) => l.set(`kt-t-${r}-${c}`, { text: String(value) }));
      for (let c = 0; c <= cap; c++) l.to(`kt-${r}-${c}`, { fill: "var(--raised)" }, { duration: 250 });
    });
    const label =
      r === 0
        ? "Row 0: no items, thus each cell is 0."
        : (() => {
            const { weight, value } = table.rows[r - 1].item;
            return `Row ${r}: the item with weight ${weight} and value ${value}. Each cell takes the larger of the cell above, and ${value} plus the cell ${weight} columns to the left in the row above.`;
          })();
    l.marker(`row-${r}`, { label });
    l.wait(150);
  });

  l.to(`kt-${rows.length - 1}-${cap}`, { fill: "var(--accent)" }, { duration: 250 });
  l.set(`kt-t-${rows.length - 1}-${cap}`, { fill: "var(--on-accent)" });
  l.marker("answer", {
    label: `The answer is the last cell, dp[${rows.length - 1}][${cap}] = ${rows[rows.length - 1][cap]}. Now walk back to find the items.`,
    pause: true,
    question: `dp[${walk[0].i}][${walk[0].c}] is ${walk[0].here}, and the cell above it is ${walk[0].above}. Was item ${walk[0].item} taken?`,
  });

  for (const step of walk) {
    // A taken item fills its cell. A skipped item only outlines it: the walk
    // passes through the cell, but the item is not in the bag.
    l.together(() => {
      if (step.take) {
        l.to(`kt-${step.i}-${step.c}`, { fill: "var(--accent)" }, { duration: 250 });
        l.set(`kt-t-${step.i}-${step.c}`, { fill: "var(--on-accent)" });
      } else {
        l.to(`kt-${step.i}-${step.c}`, { strokeWidth: 3 }, { duration: 250 });
      }
    });
    const { weight } = table.rows[step.i - 1].item;
    const label = step.take
      ? `Item ${step.item}: ${step.here} is not ${step.above}, the cell above, thus the item is in the bag. Move ${weight} columns left.`
      : `Item ${step.item}: ${step.here} is the same as the cell above, thus the item is not needed. The outline marks a skip.`;
    l.marker(`walk-${step.item}`, { label });
    l.wait(150);
  }
  const chosen = walk.filter((s) => s.take).map((s) => s.item).reverse();
  l.marker("done", { label: `The bag holds items ${chosen.join(", ")}, for a value of ${rows[rows.length - 1][cap]}.` });

  return {
    markup: tokensToStyle(figure({ width: g.width, height: g.height, title: "The knapsack table, then the walk back", children: [svgPiece(g.svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: "A table of 6 rows and 11 columns. Each row adds one item. Then a path from the bottom-right cell marks which items are in the bag.",
    caption: "The table and the walk back from the program above. A filled cell is an item in the bag, and an outlined cell is a skip. The walk stops at the answer and asks you to predict the first decision.",
  };
}

export async function knapsackDirection(): Promise<Figure> {
  const name = "knapsack-direction";
  const output = await expectedOutput(SNIPPET);
  const table = parseRows(block(output, "dp[i][c]: best value from the first i items with room c", name), name);
  const down = parseRows(block(output, "one row, capacity loop running downward", name), name);
  const up = parseRows(block(output, "one row, capacity loop running upward", name), name);
  check(down.rows.length === up.rows.length, name, "the two directions have different numbers of items");
  down.rows.forEach((row, k) => check(row.cells.join(" ") === table.rows[k].cells.join(" "), name, `the downward row after item ${k + 1} is not the table's row`));
  const cap = down.rows[0].cells.length - 1;

  const g = grid("kd", ["one row"], cap + 1);
  const play = (id: string, rows: typeof down.rows, closing: string) => {
    const l = lesson({ id });
    for (let c = 0; c <= cap; c++) l.initial(`kd-0-${c}`, { fill: "var(--sunken)" });
    for (let c = 0; c <= cap; c++) l.set(`kd-t-0-${c}`, { text: "0" });
    l.marker("start", { label: "One row of 11 cells, all 0. Each item rewrites the row in place." });
    let before = Array(cap + 1).fill(0) as number[];
    rows.forEach((row, k) => {
      l.together(() => {
        row.cells.forEach((value, c) => {
          l.set(`kd-t-0-${c}`, { text: String(value) });
          l.to(`kd-0-${c}`, { fill: value !== before[c] ? "var(--raised)" : "var(--sunken)" }, { duration: 250 });
        });
      });
      l.marker(`item-${k + 1}`, { label: `After the item with weight ${row.item.weight} and value ${row.item.value}: the last cell is ${row.cells[cap]}.` });
      l.wait(150);
      before = row.cells;
    });
    l.marker("end", { label: closing });
    return l.definition();
  };

  const first = down.rows.findIndex((row, k) => row.cells.join(" ") !== up.rows[k].cells.join(" "));
  check(first !== -1, name, "the two directions never differ");
  const at = down.rows[first].cells.findIndex((v, c) => v !== up.rows[first].cells[c]);
  const best = table.rows[table.rows.length - 1].cells[cap];
  const wrong = up.rows[up.rows.length - 1].cells[cap];
  return {
    markup: tokensToStyle(figure({ width: g.width, height: g.height, title: "The capacity loop, downward and upward", children: [svgPiece(g.svg)], theme: THEME })),
    timelines: [
      { id: "down", label: "Downward", timeline: play("down", down.rows, `Downward: ${best}. Each cell reads cells that this item did not change yet, thus each item is used one time.`) },
      { id: "up", label: "Upward", timeline: play("up", up.rows, `Upward: ${wrong}. A cell can read a cell that this item already changed, thus an item can go into the bag again.`) },
    ],
    legend: "Loop",
    alt: `One row of 11 cells, rewritten for each of 5 items. A downward loop ends at ${best}, and an upward loop ends at ${wrong}.`,
    caption: `Select a direction and step through the items. The two rows differ first after item ${first + 1}, at room ${at}: ${down.rows[first].cells[at]} downward and ${up.rows[first].cells[at]} upward.`,
  };
}
