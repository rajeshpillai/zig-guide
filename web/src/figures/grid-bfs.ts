/**
 * The grid BFS figures, built from what `23-competitive.grid-bfs` prints: the
 * finished distance field, the count of cells at each distance, and two
 * routes (the shortest one from BFS, and the first one a depth-first walk
 * finds).
 *
 * The frontier figure shows the cells at distance 0, then 1, then 2. That is
 * the order the queue hands them out, which the program checks and prints
 * ("the queue never handed back a shorter distance -> true"). The parser
 * requires the field to agree with the printed count at each distance, and
 * each route to step between neighbours and have the printed length.
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "23-competitive.grid-bfs";

/** Grid rows under a header of column numbers: `r0  S  .  #` and so on. */
function parseGrid(lines: string[], name: string): string[][] {
  const grid = lines
    .filter((line) => /^\s*r\d+\s/.test(line))
    .map((line) => line.trim().split(/\s+/).slice(1));
  check(grid.length > 0 && grid.every((r) => r.length === grid[0].length), name, "the grid rows have different lengths");
  return grid;
}

async function load(name: string) {
  const output = await expectedOutput(SNIPPET);
  const field = parseGrid(block(output, "the finished field", name), name);
  const start = parseGrid(block(output, output.split("\n")[0].trim(), name), name);
  check(start[0][0] === "S", name, "the first grid does not start at S");

  const counts = new Map<number, number>();
  const countLines = block(output, "how many cells sit at each distance", name);
  for (let i = 0; i + 1 < countLines.length; i += 2) {
    const ds = countLines[i].trim().split(/\s+/).slice(1).map(Number);
    const cs = countLines[i + 1].trim().split(/\s+/).slice(1).map(Number);
    ds.forEach((d, k) => counts.set(d, cs[k]));
  }
  for (const [d, c] of counts) {
    const here = field.flat().filter((cell) => cell === String(d)).length;
    check(here === c, name, `the field has ${here} cells at distance ${d}, but the count line says ${c}`);
  }
  return { output, field, start, max: Math.max(...counts.keys()) };
}

/**
 * The cells of a printed route. The grid shows which cells the route uses,
 * not the order: the depth-first route folds back beside itself, so a cell
 * can touch several route cells and the order cannot be read back. The figure
 * therefore shows each route whole, and checks its size against the printed
 * move count (the route visits moves + 1 cells, S and T included).
 */
function route(output: string, heading: string, name: string, moves: number): Array<[number, number]> {
  const grid = parseGrid(block(output, heading, name), name);
  const cellsOn: Array<[number, number]> = [];
  grid.forEach((row, r) => row.forEach((cell, c) => (cell === "o" || cell === "T") && cellsOn.push([r, c])));
  check(cellsOn.length === moves, name, `the route "${heading}" has ${cellsOn.length} cells after S, not ${moves}`);
  return cellsOn;
}

const CELL = 34;
const X0 = 20;
const Y0 = 20;

function gridMarkup(grid: string[][], prefix: string, numbers: string[][] | null) {
  let svg = "";
  grid.forEach((row, r) =>
    row.forEach((cell, c) => {
      const x = X0 + c * CELL;
      const y = Y0 + r * CELL;
      const wall = cell === "#" || cell === "##";
      svg += `<rect data-tinyfly="${prefix}-${r}-${c}" x="${x}" y="${y}" width="${CELL - 2}" height="${CELL - 2}" rx="4" fill="${wall ? "var(--muted)" : "var(--sunken)"}"/>`;
      if (numbers && !wall && /^\d+$/.test(numbers[r][c])) {
        svg += `<text data-tinyfly="${prefix}-n-${r}-${c}" x="${x + (CELL - 2) / 2}" y="${y + (CELL - 2) / 2}" text-anchor="middle" dominant-baseline="central" font-size="12" fill="var(--text)" style="opacity:0">${numbers[r][c]}</text>`;
      }
    }),
  );
  const width = X0 * 2 + grid[0].length * CELL;
  const height = Y0 * 2 + grid.length * CELL;
  return { svg, width, height };
}

export async function bfsFrontier(): Promise<Figure> {
  const name = "bfs-frontier";
  const { field, max } = await load(name);
  const { svg, width, height } = gridMarkup(field, "bf", field);

  const l = lesson({ id: name });
  // Each distance is hidden until its ring arrives. A track starts from the
  // default opacity of 1, not from the markup's style, so say so here.
  field.forEach((row, r) =>
    row.forEach((cell, c) => {
      if (!/^\d+$/.test(cell)) return;
      l.initial(`bf-${r}-${c}`, { fill: "var(--sunken)" });
      l.initial(`bf-n-${r}-${c}`, { opacity: 0, fill: "var(--text)" });
    }),
  );
  l.marker("start", { label: "S is at the top left and T at the bottom right. Grey cells are walls." });
  let previous: Array<[number, number]> = [];
  for (let d = 0; d <= max; d++) {
    const ring: Array<[number, number]> = [];
    field.forEach((row, r) => row.forEach((cell, c) => cell === String(d) && ring.push([r, c])));
    l.together(() => {
      for (const [r, c] of previous) {
        l.to(`bf-${r}-${c}`, { fill: "var(--raised)" }, { duration: 200 });
        l.to(`bf-n-${r}-${c}`, { fill: "var(--text)" }, { duration: 200 });
      }
      // Text on the accent fill uses the token made for it.
      for (const [r, c] of ring) {
        l.to(`bf-${r}-${c}`, { fill: "var(--accent)" }, { duration: 200 });
        l.to(`bf-n-${r}-${c}`, { opacity: 1, fill: "var(--on-accent)" }, { duration: 200 });
      }
    });
    const reachT = field[field.length - 1][field[0].length - 1] === String(d) ? " T is in this ring." : "";
    l.marker(`d-${d}`, { label: `Distance ${d}: ${ring.length} ${ring.length === 1 ? "cell" : "cells"}.${reachT}` });
    l.wait(120);
    previous = ring;
  }
  const sealed = field.flat().filter((cell) => cell === ".").length;
  l.together(() => {
    for (const [r, c] of previous) {
      l.to(`bf-${r}-${c}`, { fill: "var(--raised)" }, { duration: 200 });
      l.to(`bf-n-${r}-${c}`, { fill: "var(--text)" }, { duration: 200 });
    }
  });
  l.marker("done", {
    label: `The queue is empty after distance ${max}.${sealed ? ` ${sealed} open ${sealed === 1 ? "cell has" : "cells have"} no number: walls close ${sealed === 1 ? "it" : "them"} off.` : ""}`,
  });

  return {
    markup: tokensToStyle(figure({ width, height, title: "BFS distances, one ring at a time", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    options: { stepMode: false },
    alt: "A grid of 9 rows and 13 columns with walls. BFS numbers the cells by their distance from the top left corner, one distance at a time.",
    caption: "The finished distance field from the program above, shown in the order the queue reaches each distance. Play runs through all of them.",
  };
}

export async function bfsRoutes(): Promise<Figure> {
  const name = "bfs-routes";
  const { output, start } = await load(name);
  const short = route(output, "the shortest route:", name, 24);
  const deep = route(output, "the first route a depth-first walk finds:", name, 68);
  const moves = (path: Array<[number, number]>) => path.length;
  const { svg, width, height } = gridMarkup(start, "br", null);
  const ends =
    `<text x="${X0 + (CELL - 2) / 2}" y="${Y0 + (CELL - 2) / 2}" text-anchor="middle" dominant-baseline="central" font-size="13" font-weight="700" fill="var(--text)">S</text>` +
    `<text x="${X0 + (start[0].length - 1) * CELL + (CELL - 2) / 2}" y="${Y0 + (start.length - 1) * CELL + (CELL - 2) / 2}" text-anchor="middle" dominant-baseline="central" font-size="13" font-weight="700" fill="var(--text)" data-tinyfly="br-T">T</text>`;

  // Both scenarios colour cells of the same grid, and each route has cells
  // the other does not. Each scenario therefore resets every cell of either
  // route with \`set\`, which always makes a track; otherwise a switch from BFS
  // to DFS left the BFS-only cells coloured.
  const both = [...new Map([...short, ...deep].map(([r, c]) => [`br-${r}-${c}`, true])).keys()];
  const timeline = (id: string, path: Array<[number, number]>, label: string) => {
    const l = lesson({ id });
    for (const target of both) {
      l.initial(target, { fill: "var(--sunken)" });
      l.set(target, { fill: "var(--sunken)" });
    }
    l.initial("br-T", { fill: "var(--text)" });
    l.set("br-T", { fill: "var(--text)" });
    l.marker("start", { label: "Both walks start at S and end at T." });
    l.together(() => {
      for (const [r, c] of path) l.to(`br-${r}-${c}`, { fill: "var(--accent)" }, { duration: 500 });
      // T is on both routes, thus its letter sits on the accent fill.
      l.to("br-T", { fill: "var(--on-accent)" }, { duration: 500 });
    });
    l.marker("end", { label });
    return l.definition();
  };

  return {
    markup: tokensToStyle(figure({ width, height, title: "The BFS route and the first DFS route", children: [svgPiece(svg + ends)], theme: THEME })),
    timelines: [
      { id: "bfs", label: "BFS", timeline: timeline("bfs", short, `BFS: ${moves(short)} moves. No route from S to T is shorter.`) },
      { id: "dfs", label: "DFS", timeline: timeline("dfs", deep, `DFS: ${moves(deep)} moves. The walk goes deep first and takes the first route that reaches T.`) },
    ],
    legend: "Walk",
    alt: "The same grid twice: the BFS route reaches T in 24 moves, and the first route a depth-first walk finds takes 68.",
    caption: "Select a walk, then press Next step. Both routes come from the program above.",
  };
}
