/**
 * Figures for the Groundwork track, built from what its snippets print.
 *
 * Groundwork's rule is that an analogy must be paid off by the program on the
 * same page. These figures are drawn from that program's output, so the
 * picture and the printed numbers cannot disagree.
 */
import { cells, figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, check, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

interface Field {
  name: string;
  offset: number;
  size: number;
}

/** `name starts at byte N, size M` lines, from `from` to the next blank line. */
function fields(lines: string[], from: number): Field[] {
  const out: Field[] = [];
  for (const line of lines.slice(from)) {
    const m = line.match(/^(\w+)\s+starts at byte (\d+), size (\d+)$/);
    if (!m) break;
    out.push({ name: m[1], offset: Number(m[2]), size: Number(m[3]) });
  }
  return out;
}

const BYTE = 46;
const X0 = 20;
const Y0 = 40;

export async function structLayout(): Promise<Figure> {
  const name = "struct-layout";
  const output = await expectedOutput("15-groundwork.structs-are-layout");
  const lines = output.split("\n");
  const rowSize = Number(output.match(/@sizeOf\(Row\) = (\d+)/)?.[1]);
  const packedSize = Number(output.match(/largest first: (\d+) bytes/)?.[1]);
  const row = fields(lines, lines.findIndex((l) => l.startsWith("flag  starts")));
  const packed = fields(lines, lines.findIndex((l) => l.startsWith("same fields, largest first")) + 1);
  check(row.length === 3 && packed.length === 3 && rowSize > 0 && packedSize > 0, name, "the layout lines changed shape");

  const layouts = [
    { id: "declared", label: "Declared order", prefix: "rw", fields: row, size: rowSize },
    { id: "largest", label: "Largest first", prefix: "pk", fields: packed, size: packedSize },
  ];
  const bytes = Math.max(rowSize, packedSize);
  for (const layout of layouts) {
    const sorted = [...layout.fields].sort((a, b) => a.offset - b.offset);
    sorted.forEach((f, k) => {
      if (k > 0) check(f.offset >= sorted[k - 1].offset + sorted[k - 1].size, name, `${layout.id}: ${f.name} overlaps the field before it`);
      check(f.offset % f.size === 0, name, `${layout.id}: ${f.name} at ${f.offset} is not aligned to its size ${f.size}`);
    });
    const largest = Math.max(...layout.fields.map((f) => f.size));
    check(layout.size % largest === 0, name, `${layout.id}: the size ${layout.size} is not a multiple of ${largest}`);
  }

  // The bytes, then one block for each field of each layout, all hidden.
  let svg = `<text x="${X0}" y="${Y0 - 14}" font-size="12" fill="var(--muted)">bytes of the struct, numbered from 0</text>`;
  for (let i = 0; i < bytes; i++) {
    const x = X0 + i * BYTE;
    svg += `<rect data-tinyfly="sl-b-${i}" x="${x}" y="${Y0}" width="${BYTE - 4}" height="${BYTE - 4}" rx="4" fill="var(--sunken)" stroke="var(--muted)" stroke-width="1"/>`;
    svg += `<text data-tinyfly="sl-pad-${i}" x="${x + (BYTE - 4) / 2}" y="${Y0 + (BYTE - 4) / 2}" text-anchor="middle" dominant-baseline="central" font-size="11" fill="var(--muted)" style="opacity:0">pad</text>`;
    svg += `<text x="${x + (BYTE - 4) / 2}" y="${Y0 + BYTE + 10}" text-anchor="middle" font-size="12" fill="var(--muted)">${i}</text>`;
  }
  for (const layout of layouts) {
    for (const f of layout.fields) {
      const x = X0 + f.offset * BYTE;
      const w = f.size * BYTE - 4;
      // Hidden in the markup, not only by \`initial\`: a field of the other
      // layout never animates in this timeline, and \`initial\` alone makes no
      // track, so it would stay visible.
      svg += `<g data-tinyfly="${layout.prefix}-${f.name}" style="opacity:0"><rect x="${x}" y="${Y0}" width="${w}" height="${BYTE - 4}" rx="4" fill="var(--accent)"/>`;
      svg += `<text x="${x + w / 2}" y="${Y0 + (BYTE - 4) / 2}" text-anchor="middle" dominant-baseline="central" font-size="12" fill="var(--on-accent)">${f.name}</text></g>`;
    }
  }

  const play = (layout: (typeof layouts)[number]) => {
    const l = lesson({ id: layout.id });
    // Both scenarios draw on the same parts. Each one states the start of
    // every part with \`set\`, which always makes a track: a switch in the
    // middle of the other scenario then resets the parts this one does not
    // move, which the player's own reset did not do for them.
    const start = (target: string, opacity: number) => {
      l.initial(target, { opacity });
      l.set(target, { opacity });
    };
    for (let i = 0; i < bytes; i++) {
      start(`sl-pad-${i}`, 0);
      start(`sl-b-${i}`, 1);
    }
    for (const other of layouts) for (const f of other.fields) start(`${other.prefix}-${f.name}`, 0);
    l.marker("start", { label: `${layout.label}: ${layout.fields.map((f) => f.name).join(", ")}. The fields hold ${layout.fields.reduce((a, f) => a + f.size, 0)} bytes of data.` });

    let end = 0;
    layout.fields.forEach((f, k) => {
      const gap = f.offset - end;
      l.together(() => {
        l.to(`${layout.prefix}-${f.name}`, { opacity: 1 }, { duration: 300 });
        for (let i = end; i < f.offset; i++) l.to(`sl-pad-${i}`, { opacity: 1 }, { duration: 300 });
      });
      const place = `${f.name} takes ${f.size} ${f.size === 1 ? "byte" : "bytes"} at byte ${f.offset}.`;
      const why =
        gap > 0
          ? ` Bytes ${end} to ${f.offset - 1} are padding: a field of ${f.size} bytes starts at a byte number that is divisible by ${f.size}.`
          : "";
      l.marker(`field-${k + 1}`, { label: place + why });
      l.wait(200);
      end = f.offset + f.size;
    });

    const largest = Math.max(...layout.fields.map((f) => f.size));
    l.together(() => {
      for (let i = end; i < layout.size; i++) l.to(`sl-pad-${i}`, { opacity: 1 }, { duration: 300 });
      for (let i = layout.size; i < bytes; i++) l.to(`sl-b-${i}`, { opacity: 0.2 }, { duration: 300 });
    });
    const tail = layout.size > end ? ` Padding to byte ${layout.size - 1} makes the size a multiple of ${largest}. Thus each struct in an array starts aligned.` : "";
    l.marker("size", { label: `The fields end at byte ${end - 1}.${tail} @sizeOf is ${layout.size}.` });
    return l.definition();
  };

  const width = X0 * 2 + bytes * BYTE;
  return {
    markup: tokensToStyle(figure({ width, height: Y0 + BYTE + 24, title: "Field layout, declared order and largest first", children: [svgPiece(svg)], theme: THEME })),
    timelines: layouts.map((layout) => ({ id: layout.id, label: layout.label, timeline: play(layout) })),
    legend: "Field order",
    alt: `The struct with flag, count and tag in ${bytes} bytes. In the declared order it uses ${rowSize} bytes with padding; largest first it uses ${packedSize}.`,
    caption: "The offsets and sizes the program above prints. Select an order and step through the fields. The steps have the same names, thus you can switch at any step.",
  };
}

export async function bytesTwoWays(): Promise<Figure> {
  const name = "bytes-two-ways";
  const output = await expectedOutput("15-groundwork.everything-is-bytes");
  const one = output.match(/the u32 1, byte by byte:((?: \d+)+)/)?.[1].trim().split(" ").map(Number);
  const number = Number(output.match(/read as a number: (\d+)/)?.[1]);
  const letters = output.match(/read as letters:\s+(\S+)/)?.[1];
  check(one && number > 0 && letters, name, "the byte lines changed shape");
  check(one.length === 4 && letters.length === 4, name, "expected four bytes");
  // The letters are the bytes. Read little-endian, they must give the number
  // the program printed for the same four bytes.
  const codes = [...letters].map((c) => c.charCodeAt(0));
  const weights = [1, 256, 65536, 16777216];
  check(codes.reduce((sum, c, i) => sum + c * weights[i], 0) === number, name, "the letters do not add up to the printed number");

  const row = cells({ id: "bt", values: one, x: X0 + 70, y: Y0, size: 56, gap: 40, theme: THEME });
  const cx = (i: number) => row.center(i).x;
  let svg =
    `<text x="${X0}" y="${Y0 + 28}" font-size="12" fill="var(--muted)">memory</text>` +
    `<text x="${X0}" y="${Y0 - 14}" font-size="12" fill="var(--muted)">address +0 is first</text>`;
  weights.forEach((w, i) => {
    svg += `<text data-tinyfly="bt-w-${i}" x="${cx(i)}" y="${Y0 + 104}" text-anchor="middle" font-size="12" fill="var(--muted)" style="opacity:0">× ${w}</text>`;
    svg += `<text data-tinyfly="bt-c-${i}" x="${cx(i)}" y="${Y0 + 136}" text-anchor="middle" font-size="22" font-weight="700" fill="var(--text)" style="opacity:0">${letters[i]}</text>`;
  });
  svg += `<text data-tinyfly="bt-num" x="${cx(3) + 62}" y="${Y0 + 104}" font-size="14" fill="var(--text)" style="opacity:0">= ${number}</text>`;
  svg += `<text data-tinyfly="bt-as-u32" x="${X0}" y="${Y0 + 104}" font-size="12" fill="var(--muted)" style="opacity:0">as u32</text>`;
  svg += `<text data-tinyfly="bt-as-u8" x="${X0}" y="${Y0 + 136}" font-size="12" fill="var(--muted)" style="opacity:0">as [4]u8</text>`;

  const l = lesson({ id: name });
  const hidden = ["bt-num", "bt-as-u32", "bt-as-u8", ...weights.map((_, i) => `bt-w-${i}`), ...weights.map((_, i) => `bt-c-${i}`)];
  for (const target of hidden) l.initial(target, { opacity: 0 });
  l.marker("one", { label: `The u32 1, byte by byte: ${one.join(" ")}. The smallest place value is at the lowest address. That order is little-endian.` });
  l.together(() => codes.forEach((c, i) => row.write(l, i, c, { duration: 300 })));
  l.marker("bytes", { label: `The u32 0x41424344 in memory: ${codes.join(" ")}. The last byte holds the largest place value.` });
  l.together(() => {
    for (const t of ["bt-as-u32", "bt-num", ...weights.map((_, i) => `bt-w-${i}`)]) l.to(t, { opacity: 1 }, { duration: 300 });
  });
  l.marker("number", {
    label: `Read as one u32: ${codes.map((c, i) => `${c} × ${weights[i]}`).join(" + ")} = ${number}.`,
    pause: true,
    question: "The next step reads the same four bytes as four u8 values. Which bytes change?",
  });
  l.together(() => {
    for (const t of ["bt-as-u8", ...weights.map((_, i) => `bt-c-${i}`)]) l.to(t, { opacity: 1 }, { duration: 300 });
  });
  l.marker("letters", { label: `Read as four u8 values: ${codes.join(", ")}, which print as ${letters}. No byte changed. Only the rule for reading them changed.` });

  return {
    markup: tokensToStyle(figure({ width: X0 * 2 + 70 + 4 * 96 + 150, height: Y0 + 150, title: "Four bytes, read two ways", children: [row, svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `Four bytes in memory, ${codes.join(", ")}, read once as the u32 ${number} and once as the letters ${letters}.`,
    caption: "The bytes from the program above. The same four bytes give a number or four letters, and only the type decides which.",
  };
}
