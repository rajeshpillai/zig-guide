/**
 * Figures for the chat server project: the lines that each outbox gets for
 * each action (The Hub), and an outbox that fills while the others drain
 * (Slow Clients). Both are built from the printed traces of the snippets.
 */
import { figure, lesson } from "@algorisys/tinyfly/teach";
import { THEME, check, esc, expectedOutput, svgPiece, tokensToStyle } from "./trace";
import type { Figure } from "./index";

interface Step {
  action: string;
  /** Lines for each member, in the order the trace prints them. */
  got: Map<string, string[]>;
  note?: string;
}

/** Action lines start in column 0; delivery lines are `  name <- line`. */
function steps(lines: string[], name: string): Step[] {
  const result: Step[] = [];
  for (const line of lines) {
    if (line.trim() === "") break;
    const d = line.match(/^\s+(\w+)\s+<- (.*)$/);
    if (d) {
      const step = result[result.length - 1];
      check(step, name, `a delivery before any action: "${line}"`);
      step.got.set(d[1], [...(step.got.get(d[1]) ?? []), d[2]]);
    } else if (/^\S/.test(line)) {
      result.push({ action: line.trim(), got: new Map() });
    } else {
      const step = result[result.length - 1];
      check(step, name, `a note before any action: "${line}"`);
      step.note = line.trim();
    }
  }
  return result;
}

const members = ["tejas", "vishaka", "shivam"];
const colW = 230;
const slotH = 30;
const x0 = 20;

function columns(prefix: string, slots: number, top: number): string {
  let svg = "";
  members.forEach((m, c) => {
    const x = x0 + c * (colW + 14);
    svg += `<text x="${x}" y="${top - 10}" font-size="13" fill="var(--text)">${m}</text>`;
    svg += `<rect data-tinyfly="${prefix}-col-${c}" x="${x - 4}" y="${top - 4}" width="${colW + 8}" height="${slots * (slotH + 6) + 2}" rx="7" fill="none" stroke="var(--accent)" stroke-width="3" style="opacity:0"/>`;
    for (let s = 0; s < slots; s++) {
      const y = top + s * (slotH + 6);
      svg += `<rect x="${x}" y="${y}" width="${colW}" height="${slotH}" rx="4" fill="var(--sunken)" stroke="var(--muted)" stroke-width="1"/>`;
      svg += `<text data-tinyfly="${prefix}-${c}-${s}" x="${x + 8}" y="${y + slotH / 2}" dominant-baseline="central" font-size="12" font-family="var(--font-mono, monospace)" fill="var(--text)" style="opacity:0"></text>`;
    }
  });
  return svg;
}

/* ------------------------------------------------------------------ */
/* The Hub: one broadcast, copied into each outbox                     */
/* ------------------------------------------------------------------ */

export async function chatFanout(): Promise<Figure> {
  const name = "chat-fanout";
  const output = await expectedOutput("11-networking.chat-hub");
  const all = steps(output.split("\n"), name);
  check(all.length >= 4, name, `read ${all.length} actions`);
  // A msg goes to every member, the sender too, and each copy is the same line.
  for (const s of all) {
    const lines = [...s.got.values()].flat();
    const msg = lines.filter((l) => l.startsWith("msg "));
    if (msg.length > 0) {
      check(new Set(msg).size === 1, name, `"${s.action}" delivered different msg lines`);
      check(msg.length === s.got.size, name, `"${s.action}" did not reach each member once`);
    }
  }
  const slots = Math.max(...all.map((s) => Math.max(0, ...[...s.got.values()].map((v) => v.length))));
  const top = 40;
  const svg = columns("cf", slots, top);

  const l = lesson({ id: name });
  members.forEach((_, c) => {
    for (let s = 0; s < slots; s++) l.initial(`cf-${c}-${s}`, { opacity: 0, text: "" });
  });
  l.marker("start", { label: "Three outboxes, one for each member. The hub puts lines in. A writer task for each member takes them out and sends them." });
  all.forEach((step, k) => {
    l.together(() => {
      members.forEach((m, c) => {
        const got = step.got.get(m) ?? [];
        for (let s = 0; s < slots; s++) {
          l.set(`cf-${c}-${s}`, { text: got[s] ?? "" });
          l.to(`cf-${c}-${s}`, { opacity: got[s] ? 1 : 0 }, { duration: 200 });
        }
      });
    });
    const who = [...step.got.keys()];
    let label: string;
    if (step.note) label = `${step.action}: ${step.note.replace(/^refused: /, "the hub refuses with ")}. No outbox gets a line.`;
    else if (who.length === members.length && new Set([...step.got.values()].flat()).size === 1)
      label = `${step.action}: the same line goes into all ${who.length} outboxes, the sender's too.`;
    else label = `${step.action}: ${who.map((m) => `${m} gets ${step.got.get(m)!.length}`).join(", ")}.`;
    l.marker(`action-${k}`, { label });
    l.wait(150);
  });
  l.marker("done", { label: "The hub never touched a socket. Each line is a copy, so an outbox owns its lines and no line points into another outbox." });

  return {
    markup: tokensToStyle(figure({ width: x0 + members.length * (colW + 14) + 10, height: top + slots * (slotH + 6) + 20, title: "The hub copies each line into each outbox", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: "Three outboxes, for tejas, vishaka and shivam, and the lines that the hub puts into each one for each action.",
    caption: "The actions and deliveries from the program above, one step for each action.",
  };
}

/* ------------------------------------------------------------------ */
/* Slow Clients: one outbox fills, and the hub drops that member       */
/* ------------------------------------------------------------------ */

export async function chatSlowClient(): Promise<Figure> {
  const name = "chat-slow-client";
  const output = await expectedOutput("11-networking.chat-slow-client");
  const lines = output.split("\n");
  const capacity = Number(output.match(/outbox capacity: (\d+) lines/)?.[1]);
  check(capacity > 0, name, "no outbox capacity line");
  const start = lines.findIndex((line) => / says "/.test(line));
  check(start > 0, name, "no say actions");
  const says = steps(lines.slice(start), name).map((s) => ({
    ...s,
    member: s.note === "shivam is a member: true" ? true : s.note === "shivam is a member: false" ? false : null,
  }));
  check(says.every((s) => s.member !== null), name, "each action must end with the membership line");
  const readBack = (() => {
    const at = lines.findIndex((line) => line.startsWith("the writer of shivam reads its outbox"));
    check(at > 0, name, "no read-back block");
    const body: string[] = [];
    for (const line of lines.slice(at + 1)) {
      if (line.trim() === "") break;
      body.push(line.trim());
    }
    return body;
  })();
  const closed = readBack.pop();
  check(closed === "error.Closed: send close 1008", name, `the read-back ends "${closed}"`);

  // Replay: shivam joined last, so its outbox starts with its welcome. Each
  // say while it is a member adds one line. The first say that finds the
  // outbox full drops it, and from that step on it is not a member.
  const fill: string[] = [readBack[0]];
  check(readBack[0].startsWith("welcome shivam"), name, "the first line of shivam is not its welcome");
  let dropAt = -1;
  says.forEach((s, k) => {
    const msg = s.got.get("tejas")?.find((l) => l.startsWith("msg "));
    check(msg, name, `"${s.action}" did not reach tejas`);
    if (dropAt === -1 && fill.length < capacity) {
      fill.push(msg);
      check(s.member === true, name, `after "${s.action}" shivam has room, and the trace says it is not a member`);
    } else {
      if (dropAt === -1) dropAt = k;
      check(s.member === false, name, `after "${s.action}" the outbox of shivam is full, and the trace says it is a member`);
    }
  });
  check(dropAt >= 0, name, "shivam was never dropped");
  check(fill.join("|") === readBack.join("|"), name, `the replay fills ${fill.join("; ")}, and the writer read ${readBack.join("; ")}`);
  check(says[dropAt].got.get("tejas")!.includes("left shivam (too_slow)"), name, "the others were not told");

  const top = 40;
  const slots = capacity;
  const svg =
    columns("cs", slots, top) +
    `<text data-tinyfly="cs-drop" x="${x0 + 2 * (colW + 14)}" y="${top + slots * (slotH + 6) + 18}" font-size="13" fill="var(--text)" style="opacity:0">dropped: close 1008</text>`;

  const l = lesson({ id: name });
  members.forEach((_, c) => {
    for (let s = 0; s < slots; s++) l.initial(`cs-${c}-${s}`, { opacity: 0, text: "" });
    l.initial(`cs-col-${c}`, { opacity: 0 });
  });
  l.initial("cs-drop", { opacity: 0 });
  l.set("cs-2-0", { text: fill[0] });
  l.to("cs-2-0", { opacity: 1 }, { duration: 1 });
  l.marker("start", { label: `Each outbox holds ${capacity} lines. tejas and vishaka read each line at once. shivam reads nothing, and its welcome waits.` });
  let held = 1;
  says.forEach((s, k) => {
    const others = members.slice(0, 2).map((m) => s.got.get(m) ?? []);
    l.together(() => {
      others.forEach((got, c) => {
        for (let i = 0; i < slots; i++) {
          l.set(`cs-${c}-${i}`, { text: got[i] ?? "" });
          l.to(`cs-${c}-${i}`, { opacity: got[i] ? 1 : 0 }, { duration: 200 });
        }
      });
      if (k < dropAt) {
        l.set(`cs-2-${held}`, { text: fill[held] });
        l.to(`cs-2-${held}`, { opacity: 1 }, { duration: 200 });
      } else if (k === dropAt) {
        l.to("cs-col-2", { opacity: 1 }, { duration: 200 });
        l.to("cs-drop", { opacity: 1 }, { duration: 200 });
      }
    });
    if (k < dropAt) {
      held += 1;
      l.marker(`say-${k}`, { label: `${s.action}. tejas and vishaka read the line. shivam now holds ${held} of ${capacity}.${held === capacity ? " The outbox is full." : ""}` });
    } else if (k === dropAt) {
      l.marker(`say-${k}`, {
        label: `${s.action}. put with min 0 returns 0 for shivam: the outbox is full. The hub does not wait. It drops shivam, closes the outbox, and tells the others.`,
      });
    } else {
      l.marker(`say-${k}`, { label: `${s.action}. shivam is not a member now.` });
    }
    if (k === dropAt - 1) {
      l.marker("ask", { label: "The outbox of shivam is full.", pause: true, question: "The next message arrives. Should the hub wait for shivam, or not?" });
    }
    l.wait(150);
  });
  l.marker("done", { label: `The writer of shivam still sends the ${fill.length} lines in the outbox, then error.Closed, then close 1008.` });

  return {
    markup: tokensToStyle(figure({ width: x0 + members.length * (colW + 14) + 10, height: top + slots * (slotH + 6) + 36, title: "A slow member fills its outbox", children: [svgPiece(svg)], theme: THEME })),
    timelines: [{ id: name, timeline: l.definition() }],
    alt: `Three outboxes of ${capacity} lines. Two empty after each message. The outbox of shivam fills, and on the next message the hub drops shivam.`,
    caption: "The messages from the program above. The figure stops when the outbox of shivam is full and asks what the hub should do.",
  };
}
