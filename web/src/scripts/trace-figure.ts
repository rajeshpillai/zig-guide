/**
 * Mounts every `<TraceFigure>` on the page with tinyfly's embed player.
 *
 * A static import, bundled by Vite into this page's chunk only. Astro includes
 * a component's script on the pages that use the component, so a chapter
 * without a figure downloads none of this. It is not the dynamic `import()` of
 * a file in `public/` that the Lane Dodger notes warn about.
 *
 * `stepMode` makes Play stop at the next step. A figure here is read one state
 * at a time, and a figure that ran to the end on one press would skip the
 * questions it asks.
 */
import { mountAll } from "@algorisys/tinyfly/embed";

mountAll(document, {
  player: { stepMode: true },
  controls: { labels: { stepFormat: "Step {index} of {total}" } },
}).catch((error: unknown) => {
  // The final frame is already on the page, so a failed mount leaves a
  // readable figure. Say so in the console, which the browser gate reads.
  console.error("trace figure:", error);
});
