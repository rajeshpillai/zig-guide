/**
 * Figures for the WebSocket chapters of Networking: the two header bytes
 * field by field, the mask applied one byte at a time, and the client that
 * joins two fragments with a ping between them. Each is built from its
 * snippet's printed trace and checks the trace against itself.
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, block, check, esc, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

const hex = (n: number) => n.toString(16).padStart(2, "0");

/* ------------------------------------------------------------------ */
/* WebSocket Frames: the two header bytes                              */
/* ------------------------------------------------------------------ */

interface Field {
  names: string[];
  low: number;
  high: number;
}

/** `Header0: opcode=0-3 rsv3=4 ...` into fields, highest bits first, with the rsv bits as one. */
function layout(line: string, name: string): Field[] {
  const fields = [...line.matchAll(/(\w+)=(\d+)(?:-(\d+))?/g)].map((m) => ({
    names: [m[1]],
    low: Number(m[2]),
    high: Number(m[3] ?? m[2]),
  }));
  const bits = fields.flatMap((f) => Array.from({ length: f.high - f.low + 1 }, (_, k) => f.low + k)).sort((a, b) => a - b);
  check(bits.join(",") === "0,1,2,3,4,5,6,7", name, `the fields in "${line.trim()}" do not cover bits 0 to 7 once each`);
  fields.sort((a, b) => b.high - a.high);
  const merged: Field[] = [];
  for (const f of fields) {
    const last = merged[merged.length - 1];
    if (last && last.names[0].startsWith("rsv") && f.names[0].startsWith("rsv") && last.low === f.high + 1) {
      last.names.push(...f.names);
      last.low = f.low;
    } else {
      merged.push({ ...f });
    }
  }
  return merged;
}

export async function websocketHeaderBits(): Promise<Figure> {
  const name = "websocket-header-bits";
  const output = await expectedOutput("11-networking.websocket-frames");
  const structs = block(output, "the header structs in std", name);
  const h0Line = structs.find((l) => l.trim().startsWith("Header0:"));
  const h1Line = structs.find((l) => l.trim().startsWith("Header1:"));
  check(h0Line && h1Line, name, "no Header0 or Header1 line");
  const rows = block(output, "the first two bytes", name).map((line) => line.match(/byte (\d) = ([01]{8}): (.*)$/));
  check(rows.length === 2 && rows.every(Boolean), name, "the two byte rows did not parse");
  const bytes = rows.map((m) => m![2]);
  const decoded0 = rows[0]![3];
  const decoded1 = rows[1]![3];
  // The decoded fields must be the bits: fin is bit 7, opcode the low 4, and so on.
  const b0 = parseInt(bytes[0], 2);
  const b1 = parseInt(bytes[1], 2);
  check(decoded0.includes(`fin=${b0 >> 7 ? "true" : "false"}`), name, `fin in "${decoded0}" is not bit 7 of ${bytes[0]}`);
  check((b0 & 0xf) === 1 && decoded0.includes("opcode=text"), name, `opcode 1 is text, and "${decoded0}" disagrees`);
  check(decoded1.includes(`mask=${b1 >> 7 ? "true" : "false"}`), name, `mask in "${decoded1}" is not bit 7 of ${bytes[1]}`);
  check(decoded1.includes(`length=${b1 & 0x7f}`), name, `length in "${decoded1}" is not the low 7 bits of ${bytes[1]}`);

  const fields = [layout(h0Line, name), layout(h1Line, name)];
  const size = 40;
  const gap = 4;
  const x0 = 120;
  const ys = [40, 160];
  const xOf = (bit: number) => x0 + (7 - bit) * (size + gap);
  let svg = "";
  bytes.forEach((bits, row) => {
    svg += `<text x="20" y="${ys[row] + size / 2}" dominant-baseline="central" font-size="13" fill="var(--text)">byte ${row} = ${hex(parseInt(bits, 2))}</text>`;
    for (let bit = 7; bit >= 0; bit--) {
      const x = xOf(bit);
      svg += `<rect x="${x}" y="${ys[row]}" width="${size}" height="${size}" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="1.5"/>`;
      svg += `<text x="${x + size / 2}" y="${ys[row] + size / 2}" text-anchor="middle" dominant-baseline="central" font-size="16" fill="var(--text)">${bits[7 - bit]}</text>`;
      svg += `<text x="${x + size / 2}" y="${ys[row] - 8}" text-anchor="middle" font-size="11" fill="var(--muted)">${bit}</text>`;
    }
    svg += `<text data-tinyfly="hb-name-${row}" x="${x0}" y="${ys[row] + size + 22}" font-size="13" fill="var(--text)"></text>`;
  });
  svg += `<rect data-tinyfly="hb-sel" x="${xOf(7) - 4}" y="${ys[0] - 4}" width="${size + 8}" height="${size + 8}" rx="7" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;

  const explain: Record<string, string> = {
    fin: "1 means that this frame is the last part of its message.",
    rsv1: "An extension can use these bits. Without an extension they are 0.",
    mask: "1 means that the sender masked the payload. A client sets it on each frame.",
  };
  const l = lesson({ id: name });
  l.initial("hb-sel", { opacity: 0, x: 0, y: 0, width: size + 8 });
  for (const row of [0, 1]) l.initial(`hb-name-${row}`, { text: "" });
  l.marker("start", { label: `Two header bytes, ${hex(b0)} ${hex(b1)}. Bit 7 is on the left, as RFC 6455 draws it.` });
  fields.forEach((list, row) => {
    for (const f of list) {
      const value = bytes[row].slice(7 - f.high, 8 - f.low);
      const label = f.names.length > 1 ? f.names.join(", ") : f.names[0];
      const range = f.low === f.high ? `bit ${f.low}` : `bits ${f.high} to ${f.low}`;
      l.together(() => {
        l.to("hb-sel", { opacity: 1, x: xOf(f.high) - xOf(7), y: ys[row] - ys[0], width: (f.high - f.low + 1) * (size + gap) - gap + 8 }, { duration: 300 });
        l.set(`hb-name-${row}`, { text: `${label} = ${value}` });
      });
      let meaning = explain[f.names[0]] ?? "";
      if (f.names[0] === "opcode") {
        meaning = `${parseInt(value, 2)} is text. Header0 declares opcode first, and Zig puts the first field in the lowest bits.`;
      } else if (f.names[0] === "payload_len") {
        meaning = `That is ${parseInt(value, 2)}. A value of 126 or 127 would mean that a longer length follows.`;
      } else if (f.names[0] === "fin") {
        meaning += " Header0 declares fin last, thus fin has the highest bit.";
      }
      l.marker(`b${row}-${f.names[0]}`, { label: `Byte ${row}, ${range}: ${label} = ${value}. ${meaning}` });
      l.wait(120);
    }
  });
  l.to("hb-sel", { opacity: 0 }, { duration: 200 });
  l.marker("done", { label: `A @bitCast of each byte to Header0 and Header1 gives these fields: ${decoded0}, ${decoded1}.` });

  return {
    markup: tokensToStyle(figure({ width: xOf(0) + size + 30, height: ys[1] + size + 40, title: "The two header bytes of a WebSocket frame", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `The bytes ${hex(b0)} and ${hex(b1)} as 16 bits, with each field of Header0 and Header1 marked in turn.`,
    caption: "The layout and the two bytes from the program above. Step through the fields from bit 7 to bit 0.",
  };
}

/* ------------------------------------------------------------------ */
/* WebSocket Frames: the mask, one byte at a time                      */
/* ------------------------------------------------------------------ */

export async function websocketMask(): Promise<Figure> {
  const name = "websocket-mask";
  const output = await expectedOutput("11-networking.websocket-frames");
  const heading = output.split("\n").find((line) => line.startsWith("mask a client frame, mask "));
  check(heading, name, "no line naming the mask");
  const mask = heading.match(/mask ((?:[0-9a-f]{2} ?){4}):/)?.[1].trim().split(" ").map((h) => parseInt(h, 16));
  check(mask && mask.length === 4, name, "the mask is not four bytes");
  const rows = block(output, "mask a client frame", name)
    .map((line) => line.match(/^\s*(\d+)\s+'(.)' ([0-9a-f]{2}) \^ ([0-9a-f]{2}) = ([0-9a-f]{2})$/))
    .filter((m): m is RegExpMatchArray => m !== null)
    .map((m) => ({ i: Number(m[1]), char: m[2], byte: parseInt(m[3], 16), key: parseInt(m[4], 16), out: parseInt(m[5], 16) }));
  check(rows.length > 4, name, `read ${rows.length} rows; the figure needs more than 4 to show the mask repeat`);
  rows.forEach((r, k) => {
    check(r.i === k, name, `row ${k} has index ${r.i}`);
    check(r.char.charCodeAt(0) === r.byte, name, `'${r.char}' is not ${hex(r.byte)}`);
    check(r.key === mask[k % 4], name, `byte ${k} uses ${hex(r.key)}, not mask byte ${k % 4}`);
    check((r.byte ^ r.key) === r.out, name, `${hex(r.byte)} ^ ${hex(r.key)} is not ${hex(r.out)}`);
  });
  const frame = output.split("\n").find((line) => line.startsWith("frame: "))?.slice(7).trim();
  const header = [0x81, 0x80 | rows.length];
  const expected = [...header, ...mask, ...rows.map((r) => r.out)].map(hex).join(" ");
  check(frame === expected, name, `the frame "${frame}" is not the header, the mask and the masked bytes "${expected}"`);
  check(output.includes("the same as RFC 6455: true"), name, "the program did not match the RFC bytes");

  const size = 46;
  const gap = 8;
  const x0 = 110;
  const ys = { text: 10, payload: 50, mask: 114, out: 186 };
  const xOf = (i: number) => x0 + i * (size + gap);
  const cell = (x: number, y: number, label: string, attrs = "") =>
    `<rect x="${x}" y="${y}" width="${size}" height="${size}" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="1.5"/>` +
    `<text x="${x + size / 2}" y="${y + size / 2}" text-anchor="middle" dominant-baseline="central" font-size="15" fill="var(--text)"${attrs}>${label}</text>`;
  let svg = "";
  const side = (y: number, label: string) =>
    `<text x="16" y="${y + size / 2}" dominant-baseline="central" font-size="13" fill="var(--muted)">${label}</text>`;
  svg += side(ys.payload, "payload") + side(ys.mask, "mask") + side(ys.out, "on the wire");
  rows.forEach((r, i) => {
    svg += `<text x="${xOf(i) + size / 2}" y="${ys.text + 20}" text-anchor="middle" font-size="15" fill="var(--text)">'${esc(r.char)}'</text>`;
    svg += cell(xOf(i), ys.payload, hex(r.byte));
    svg += `<rect data-tinyfly="mk-k-${i}" x="${xOf(i)}" y="${ys.mask}" width="${size}" height="${size}" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="1.5"/>`;
    svg += `<text x="${xOf(i) + size / 2}" y="${ys.mask + size / 2}" text-anchor="middle" dominant-baseline="central" font-size="15" fill="var(--text)">${hex(r.key)}</text>`;
    svg += `<text x="${xOf(i) + size / 2}" y="${ys.mask + size + 14}" text-anchor="middle" font-size="11" fill="var(--muted)">[${i % 4}]</text>`;
    svg += `<rect x="${xOf(i)}" y="${ys.out}" width="${size}" height="${size}" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="1.5"/>`;
    svg += `<text data-tinyfly="mk-o-${i}" x="${xOf(i) + size / 2}" y="${ys.out + size / 2}" text-anchor="middle" dominant-baseline="central" font-size="15" fill="var(--text)" style="opacity:0">${hex(r.out)}</text>`;
  });
  svg += `<rect data-tinyfly="mk-col" x="${xOf(0) - 5}" y="${ys.payload - 5}" width="${size + 10}" height="${ys.out + size - ys.payload + 10}" rx="8" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;

  const l = lesson({ id: name });
  l.initial("mk-col", { opacity: 0, x: 0 });
  rows.forEach((_, i) => {
    l.initial(`mk-o-${i}`, { opacity: 0 });
    l.initial(`mk-k-${i}`, { fill: "var(--surface)" });
  });
  l.marker("start", { label: `"${rows.map((r) => r.char).join("")}" and the mask ${mask.map(hex).join(" ")}. Each payload byte gets an XOR with one mask byte.` });
  rows.forEach((r, i) => {
    if (i === 4) {
      l.marker("ask", {
        label: "The mask has four bytes, and the payload has more.",
        pause: true,
        question: `Byte 4 is '${r.char}'. Which mask byte does it use?`,
      });
    }
    l.together(() => {
      l.to("mk-col", { opacity: 1, x: xOf(i) - xOf(0) }, { duration: 250 });
      if (i > 0) l.to(`mk-k-${i - 1}`, { fill: "var(--surface)" }, { duration: 150 });
      l.to(`mk-k-${i}`, { fill: "var(--raised)" }, { duration: 150 });
      l.to(`mk-o-${i}`, { opacity: 1 }, { duration: 250 });
    });
    const repeat = i >= 4 ? ` The mask starts again: ${i} % 4 is ${i % 4}.` : "";
    l.marker(`byte-${i}`, { label: `Byte ${i}: ${hex(r.byte)} ^ ${hex(r.key)} = ${hex(r.out)}, with mask byte ${i % 4}.${repeat}` });
    l.wait(120);
  });
  l.together(() => {
    l.to("mk-col", { opacity: 0 }, { duration: 200 });
    l.to(`mk-k-${rows.length - 1}`, { fill: "var(--surface)" }, { duration: 150 });
  });
  l.marker("done", { label: `The frame is ${frame}: two header bytes, the mask, then the masked payload. These are the bytes in RFC 6455. The same XOR on the server gives "${rows.map((r) => r.char).join("")}" back.` });

  return {
    markup: tokensToStyle(figure({ width: xOf(rows.length) + 20, height: ys.out + size + 20, title: "Masking a client frame", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `The payload "${rows.map((r) => r.char).join("")}", the four mask bytes repeated under it, and the XOR of each pair.`,
    caption: "The mask trace from the program above. The figure stops at byte 4 and asks you which mask byte it uses.",
  };
}

/* ------------------------------------------------------------------ */
/* A WebSocket Client: two fragments with a ping between them          */
/* ------------------------------------------------------------------ */

interface ServerFrame {
  opcode: string;
  fin: boolean;
  payload: string;
  code?: number;
}

export async function websocketFragments(): Promise<Figure> {
  const name = "websocket-fragments";
  const output = await expectedOutput("11-networking.websocket-client");
  const frames: ServerFrame[] = block(output, "server sends 101, then these frames", name).map((line) => {
    const m = line.match(/^\s*(\w+)\s+fin=([01]) (?:"(.*)"|code (\d+))$/);
    check(m, name, `the frame line "${line.trim()}" did not parse`);
    return { opcode: m[1], fin: m[2] === "1", payload: m[3] ?? "", code: m[4] ? Number(m[4]) : undefined };
  });
  const printed = block(output, "client receives:", name).map((line) => line.trim());

  // Replay the rules of `receive` over the frames, and require the events
  // that the program printed.
  interface Step {
    buffer: string;
    reply: string;
    event: string;
  }
  const steps: Step[] = [];
  let open: string | null = null;
  let buffer = "";
  for (const f of frames) {
    let reply = "";
    let event = "";
    if (f.opcode === "ping") {
      check(f.fin, name, "a ping in fragments");
      reply = `pong "${f.payload}"`;
      event = `ping "${f.payload}", answered with a pong`;
    } else if (f.opcode === "connection_close") {
      reply = `close ${f.code}`;
      event = `close ${f.code}, answered with close ${f.code}`;
    } else {
      if (f.opcode === "continuation") check(open !== null, name, "a continuation with no message open");
      else {
        check(open === null, name, `a new ${f.opcode} message while one is open`);
        open = f.opcode;
        buffer = "";
      }
      buffer += f.payload;
      if (f.fin) {
        event = `${open} "${buffer}"`;
        open = null;
      }
    }
    // A data frame shows the message so far. A control frame leaves the
    // buffer as it is if a message is open.
    const data = f.opcode !== "ping" && f.opcode !== "connection_close";
    steps.push({ buffer: data || open !== null ? buffer : "", reply, event });
  }
  const events = steps.map((s) => s.event).filter(Boolean);
  check(events.join("|") === printed.join("|"), name, `the replay gives ${events.join("; ")}, and the program printed ${printed.join("; ")}`);
  check(frames.some((f, k) => f.opcode === "ping" && k > 0 && frames[k - 1].fin === false), name, "no ping between two fragments; the figure has nothing to show");

  const rowH = 38;
  const x0 = 20;
  const top = 50;
  const colBuf = 330;
  const colReply = 520;
  const colEvent = 640;
  let svg = `<text x="${x0}" y="${top - 16}" font-size="12" fill="var(--muted)">frames from the server</text>`;
  svg += `<text x="${colBuf}" y="${top - 16}" font-size="12" fill="var(--muted)">fragment buffer</text>`;
  svg += `<text x="${colReply}" y="${top - 16}" font-size="12" fill="var(--muted)">client sends</text>`;
  svg += `<text x="${colEvent}" y="${top - 16}" font-size="12" fill="var(--muted)">receive returns</text>`;
  frames.forEach((f, k) => {
    const y = top + k * rowH;
    const label = f.opcode === "connection_close" ? `close, code ${f.code}` : `${f.opcode} fin=${f.fin ? 1 : 0} "${esc(f.payload)}"`;
    svg += `<rect data-tinyfly="wf-f-${k}" x="${x0}" y="${y}" width="290" height="${rowH - 8}" rx="4" fill="var(--surface)" stroke="var(--muted)" stroke-width="1.5" style="opacity:0.4"/>`;
    svg += `<text x="${x0 + 10}" y="${y + (rowH - 8) / 2}" dominant-baseline="central" font-size="13" font-family="var(--font-mono, monospace)" fill="var(--text)">${label}</text>`;
    svg += `<text data-tinyfly="wf-r-${k}" x="${colReply}" y="${y + (rowH - 8) / 2}" dominant-baseline="central" font-size="13" fill="var(--text)" style="opacity:0">${esc(steps[k].reply)}</text>`;
    svg += `<text data-tinyfly="wf-e-${k}" x="${colEvent}" y="${y + (rowH - 8) / 2}" dominant-baseline="central" font-size="13" fill="var(--text)" style="opacity:0">${esc(steps[k].event.replace(/, answered with .*/, ""))}</text>`;
  });
  svg += `<rect x="${colBuf}" y="${top}" width="170" height="${rowH - 8}" rx="4" fill="var(--sunken)" stroke="var(--muted)" stroke-width="1.5"/>`;
  svg += `<text data-tinyfly="wf-buf" x="${colBuf + 10}" y="${top + (rowH - 8) / 2}" dominant-baseline="central" font-size="14" font-family="var(--font-mono, monospace)" fill="var(--text)"></text>`;
  svg += `<rect data-tinyfly="wf-sel" x="${x0 - 4}" y="${top - 4}" width="298" height="${rowH}" rx="6" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;
  svg += `<rect data-tinyfly="wf-mark" x="${colBuf}" y="${top}" width="170" height="${rowH - 8}" rx="4" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;

  const l = lesson({ id: name });
  l.initial("wf-buf", { text: "" });
  l.initial("wf-mark", { opacity: 0, y: 0 });
  l.initial("wf-sel", { opacity: 0, y: 0 });
  frames.forEach((_, k) => {
    l.initial(`wf-f-${k}`, { opacity: 0.4 });
    l.initial(`wf-r-${k}`, { opacity: 0 });
    l.initial(`wf-e-${k}`, { opacity: 0 });
  });
  l.marker("start", { label: `${frames.length} frames arrive. The client reads them from the top, one call to receive at a time.` });
  frames.forEach((f, k) => {
    const s = steps[k];
    l.together(() => {
      if (k > 0) l.to(`wf-f-${k - 1}`, { opacity: 0.4 }, { duration: 150 });
      l.to(`wf-f-${k}`, { opacity: 1 }, { duration: 200 });
      l.to("wf-sel", { opacity: 1, y: k * rowH }, { duration: 250 });
      l.set("wf-buf", { text: s.buffer ? `"${s.buffer}"` : "" });
      l.to("wf-mark", { opacity: s.buffer && !s.event ? 1 : 0, y: 0 }, { duration: 200 });
      if (s.reply) l.to(`wf-r-${k}`, { opacity: 1 }, { duration: 250 });
      if (s.event) l.to(`wf-e-${k}`, { opacity: 1 }, { duration: 250 });
    });
    let label: string;
    if (f.opcode === "ping") {
      label = `A ping between two fragments. The client sends the pong now and returns the ping. The buffer still holds "${s.buffer}", because the fragment state is in fields of Client, not in locals.`;
    } else if (f.opcode === "connection_close") {
      label = `The server closes with code ${f.code}. The client answers with the same code, and the close handshake is complete.`;
    } else if (!f.fin) {
      label = `${f.opcode} with fin=0: the first part of a message. The client keeps "${s.buffer}" and reads the next frame. No event yet.`;
    } else if (f.opcode === "continuation") {
      label = `The continuation has fin=1. The message is complete: ${s.event}. The client checks the UTF-8 now, not before.`;
    } else {
      label = `A complete ${f.opcode} message in one frame: ${s.event}.`;
    }
    l.marker(`frame-${k}`, { label });
    l.wait(150);
  });
  l.together(() => {
    l.to(`wf-f-${frames.length - 1}`, { opacity: 0.4 }, { duration: 150 });
    l.to("wf-sel", { opacity: 0 }, { duration: 150 });
  });
  l.marker("done", { label: `${frames.length} frames gave ${events.length} events, and the client sent ${steps.filter((s) => s.reply).length} frames back.` });

  return {
    markup: tokensToStyle(figure({ width: colEvent + 170, height: top + frames.length * rowH + 20, title: "Two fragments with a ping between them", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `${frames.length} frames from a server, including a text message in two fragments with a ping between them, and what the client does for each frame.`,
    caption: "The frames and the events from the program above, one step for each frame.",
  };
}
