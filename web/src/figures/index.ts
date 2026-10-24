/**
 * The stepped figures, by name. `<TraceFigure name>` looks a name up here, so
 * an unknown name fails the build the way an unknown `<Playground name>` does.
 */
import type { TimelineDefinition } from "@algorisys/tinyfly";
import { binarySearchStall, binarySearchSteps } from "./binary-search";
import { crcSteps } from "./comptime";
import { bfsFrontier, bfsRoutes } from "./grid-bfs";
import { bytesTwoWays, structLayout } from "./groundwork";
import { knapsackDirection, knapsackTable } from "./knapsack";
import { monotonicStack } from "./monotonic-stack";
import { shortestRun } from "./sliding-window";
import { containerWater } from "./two-pointers";
import { unionFindForest } from "./union-find";

export interface Figure {
  /** The SVG, with `data-tinyfly` names on each part that moves. */
  markup: string;
  /** One timeline, or one for each scenario the reader can select. */
  timelines: Array<{ id: string; label?: string; timeline: TimelineDefinition }>;
  /** The name of the choice between scenarios, for example "Branch". */
  legend?: string;
  /**
   * Player options for this figure, which win over the page-wide ones. A
   * figure with many short steps sets `stepMode: false`, so Play runs it.
   */
  options?: Record<string, unknown>;
  /** The accessible name of the figure. */
  alt: string;
  caption: string;
}

const FIGURES: Record<string, () => Promise<Figure>> = {
  "binary-search-steps": binarySearchSteps,
  "binary-search-stall": binarySearchStall,
  "monotonic-stack": monotonicStack,
  "container-water": containerWater,
  "shortest-run": shortestRun,
  "bfs-frontier": bfsFrontier,
  "bfs-routes": bfsRoutes,
  "knapsack-table": knapsackTable,
  "knapsack-direction": knapsackDirection,
  "union-find-forest": unionFindForest,
  "struct-layout": structLayout,
  "bytes-two-ways": bytesTwoWays,
  "crc-steps": crcSteps,
};

const built = new Map<string, Promise<Figure>>();

export function buildFigure(name: string): Promise<Figure> {
  const make = FIGURES[name];
  if (!make) {
    throw new Error(`Unknown figure "${name}". Known: ${Object.keys(FIGURES).join(", ")}`);
  }
  if (!built.has(name)) built.set(name, make());
  return built.get(name)!;
}
