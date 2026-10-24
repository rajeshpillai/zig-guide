/**
 * The CRC-32 figure for Build Lookup Tables, built from what
 * `25-comptime.lookup-tables` prints: the eight steps for byte 1, and the
 * table entry they produce.
 *
 * The polynomial is read from the snippet's own source. The parser replays
 * each step from the one before it and requires the printed low bit and the
 * printed register, then requires the last register to be the printed
 * `table[1]`, which the program also compared and printed as "same".
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { findSnippet, snippetSource } from "../snippets";
import { THEME, block, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const SNIPPET = "25-comptime.lookup-tables";

const BIT = 18;
const X0 = 20;
const REG_Y = 40;
const POLY_Y = 104;
const GRID_Y = 172;
const GRID_CELL = 14;

const bits = (value: number) => Array.from({ length: 32 }, (_, i) => (value >>> (31 - i)) & 1);
const hex = (value: number) => `0x${(value >>> 0).toString(16).padStart(8, "0")}`;

export async function crcSteps(): Promise<Figure> {
  const name = "crc-steps";
  const output = await expectedOutput(SNIPPET);
  const source = await snippetSource(await findSnippet(SNIPPET));
  const polyText = source.match(/const poly: u32 = (0x[0-9A-Fa-f]+);/)?.[1];
  check(polyText, name, "no `const poly: u32 = 0x…;` in the snippet");
  const poly = Number(polyText);

  const lines = block(output, "the 8 steps for byte 1", name);
  const start = Number(lines[0].match(/start\s+(0x[0-9a-f]+)/)?.[1]);
  check(start === 1, name, "the trace does not start from byte 1");
  const steps = lines
    .map((l) => l.match(/step (\d) {2}low bit (\d), (shift, then xor|shift)\s+(0x[0-9a-f]+)/))
    .filter((m): m is RegExpMatchArray => m !== null)
    .map((m) => ({ low: Number(m[2]), xor: m[3] !== "shift", value: Number(m[4]) }));
  check(steps.length === 8, name, `expected 8 steps, found ${steps.length}`);
  let c = start;
  steps.forEach((s, k) => {
    check(s.low === (c & 1) && s.xor === (s.low === 1), name, `step ${k + 1}: the low bit of ${hex(c)} is ${c & 1}, not ${s.low}`);
    c = ((c >>> 1) ^ (s.low ? poly : 0)) >>> 0;
    check(c === s.value, name, `step ${k + 1}: the replayed register ${hex(c)} is not the printed ${hex(s.value)}`);
  });
  const entry = lines.join("\n").match(/table\[1\] = (0x[0-9a-f]+), same -> true/);
  check(entry && Number(entry[1]) === c, name, "the last register is not the printed table[1]");
  const count = Number(output.match(/table: (\d+) entries/)?.[1]);
  check(count === 256, name, "the table is not 256 entries");

  // The register and the polynomial, one cell for each bit. Bit 0, the low
  // bit, is on the right, because a shift right moves each bit one cell right.
  let svg = `<text x="${X0}" y="${REG_Y - 12}" font-size="12" fill="var(--muted)">register c (bit 31 on the left, bit 0 on the right)</text>`;
  svg += `<text x="${X0}" y="${POLY_Y - 12}" font-size="12" fill="var(--muted)">polynomial ${polyText}</text>`;
  const startBits = bits(start);
  const polyBits = bits(poly);
  for (let i = 0; i < 32; i++) {
    const x = X0 + i * BIT;
    svg += `<rect data-tinyfly="cr-r-${i}" x="${x}" y="${REG_Y}" width="${BIT - 2}" height="24" rx="2" fill="var(--sunken)"/>`;
    svg += `<text data-tinyfly="cr-rb-${i}" x="${x + (BIT - 2) / 2}" y="${REG_Y + 12}" text-anchor="middle" dominant-baseline="central" font-size="12" fill="var(--text)">${startBits[i]}</text>`;
    svg += `<rect data-tinyfly="cr-p-${i}" x="${x}" y="${POLY_Y}" width="${BIT - 2}" height="24" rx="2" fill="var(--sunken)"/>`;
    svg += `<text data-tinyfly="cr-pb-${i}" x="${x + (BIT - 2) / 2}" y="${POLY_Y + 12}" text-anchor="middle" dominant-baseline="central" font-size="12" fill="var(--muted)">${polyBits[i]}</text>`;
  }
  svg += `<text data-tinyfly="cr-hex" x="${X0 + 32 * BIT + 12}" y="${REG_Y + 12}" dominant-baseline="central" font-size="14" fill="var(--text)">${hex(start)}</text>`;
  // The table: 256 entries in a 16 by 16 grid, hidden until the end.
  svg += `<g data-tinyfly="cr-grid" style="opacity:0"><text x="${X0}" y="${GRID_Y - 10}" font-size="12" fill="var(--muted)">the table: ${count} entries, made during compilation</text>`;
  for (let i = 0; i < count; i++) {
    const x = X0 + (i % 16) * GRID_CELL;
    const y = GRID_Y + Math.floor(i / 16) * GRID_CELL;
    svg += `<rect x="${x}" y="${y}" width="${GRID_CELL - 2}" height="${GRID_CELL - 2}" rx="2" fill="${i === 1 ? "var(--accent)" : "var(--raised)"}"/>`;
  }
  svg += `<text x="${X0 + 16 * GRID_CELL + 16}" y="${GRID_Y + 8}" dominant-baseline="central" font-size="13" fill="var(--text)">table[1] = ${hex(c)}</text></g>`;

  const l = lesson({ id: name });
  l.initial("cr-grid", { opacity: 0 });
  for (let i = 0; i < 32; i++) {
    l.initial(`cr-p-${i}`, { fill: "var(--sunken)" });
    l.initial(`cr-pb-${i}`, { fill: "var(--muted)" });
    l.initial(`cr-r-${i}`, { fill: "var(--sunken)" });
    l.initial(`cr-rb-${i}`, { fill: "var(--text)" });
  }
  l.marker("start", { label: `The register starts as the byte, 1. Each step looks at the low bit, on the right.` });

  let before = start;
  steps.forEach((s, k) => {
    const next = bits(s.value);
    const was = bits(before);
    l.together(() => {
      for (let i = 0; i < 32; i++) {
        const changed = next[i] !== was[i];
        const used = s.xor && polyBits[i] === 1;
        l.set(`cr-rb-${i}`, { text: String(next[i]), fill: changed ? "var(--on-accent)" : "var(--text)" });
        l.to(`cr-r-${i}`, { fill: changed ? "var(--accent)" : "var(--sunken)" }, { duration: 200 });
        l.set(`cr-pb-${i}`, { fill: used ? "var(--on-accent)" : "var(--muted)" });
        l.to(`cr-p-${i}`, { fill: used ? "var(--accent)" : "var(--sunken)" }, { duration: 200 });
      }
      l.set("cr-hex", { text: hex(s.value) });
    });
    const label = s.xor
      ? `Step ${k + 1}: the low bit is 1. Shift right by one, then xor with the polynomial. The register is ${hex(s.value)}.`
      : `Step ${k + 1}: the low bit is 0. Shift right by one. The register is ${hex(s.value)}.`;
    l.marker(`step-${k + 1}`, { label });
    l.wait(150);
    before = s.value;
  });

  l.together(() => {
    l.to("cr-grid", { opacity: 1 }, { duration: 400 });
    for (let i = 0; i < 32; i++) {
      l.to(`cr-p-${i}`, { fill: "var(--sunken)" }, { duration: 200 });
      l.set(`cr-pb-${i}`, { fill: "var(--muted)" });
    }
  });
  l.marker("table", {
    label: `After 8 steps the register is ${hex(c)}, the entry table[1]. The compiler does the same 8 steps for each of the ${count} bytes, and the binary keeps only the ${count} results.`,
  });

  return {
    markup: tokensToStyle(figure({ width: X0 * 2 + 32 * BIT + 110, height: GRID_Y + 16 * GRID_CELL + 12, title: "Eight steps make one table entry", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `A 32-bit register that starts at 1. Eight shift steps, two with an xor of the polynomial ${polyText}, give ${hex(c)}, entry 1 of a ${count}-entry table.`,
    caption: "The steps for byte 1, as the program above prints them. The bits that a step changed are filled. On a step that xors, the 1 bits of the polynomial are filled too.",
  };
}
