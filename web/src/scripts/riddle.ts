/**
 * Plays a riddle short inside its card instead of sending the reader away.
 *
 * Every `a[data-short]` is a working link to YouTube in the markup, so with
 * JavaScript off it still opens the video. With it on, two things can swap the
 * link for a youtube-nocookie player:
 *
 * - A plain click, on any card. A click with a modifier key, or a middle
 *   click, is left alone so "open in new tab" works.
 * - Scrolling a `[data-autoplay]` card (the one at the foot of a chapter or
 *   post) half into view. Browsers allow autoplay only when muted, so it
 *   starts silent and the reader turns the sound on in the player. It pauses
 *   when the card leaves the screen and resumes when it comes back, unless
 *   the reader paused it. Reduced motion and data saver turn it off, and those
 *   readers get the Play button.
 *
 * Until one of those happens nothing from YouTube is requested, which is what
 * the privacy page says.
 */
const ORIGIN = "https://www.youtube-nocookie.com";

/** YouTube's player states, from its iframe API. */
const PLAYING = 1;
const PAUSED = 2;

function embed(link: HTMLAnchorElement, { muted }: { muted: boolean }): HTMLIFrameElement | null {
  const id = link.dataset.short;
  const card = link.closest<HTMLElement>("[data-short-card]");
  if (!id || !card) return null;

  const params = new URLSearchParams({
    autoplay: "1",
    playsinline: "1",
    rel: "0",
    // Lets the page pause and resume the player with postMessage.
    enablejsapi: "1",
    origin: location.origin,
  });
  if (muted) params.set("mute", "1");

  const frame = document.createElement("iframe");
  frame.className = "riddle-player";
  frame.src = `${ORIGIN}/embed/${encodeURIComponent(id)}?${params}`;
  frame.title = link.dataset.title ?? "Riddle video";
  frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
  frame.allowFullscreen = true;
  frame.referrerPolicy = "strict-origin-when-cross-origin";

  link.replaceWith(frame);
  card.classList.add("is-playing");
  return frame;
}

function command(frame: HTMLIFrameElement, func: "playVideo" | "pauseVideo") {
  frame.contentWindow?.postMessage(JSON.stringify({ event: "command", func, args: [] }), ORIGIN);
}

/**
 * Follows one player's state, so scrolling back resumes only a video that
 * scrolling away paused, never one the reader paused.
 */
function watch(frame: HTMLIFrameElement, card: HTMLElement) {
  let state = -1;
  let pausedByScroll = false;

  window.addEventListener("message", (event) => {
    if (event.origin !== ORIGIN || event.source !== frame.contentWindow) return;
    try {
      const data = typeof event.data === "string" ? JSON.parse(event.data) : event.data;
      const next = data?.info?.playerState;
      if (typeof next === "number") state = next;
    } catch {
      // Not a player message.
    }
  });
  // The player reports its state only after the page says it is listening.
  frame.addEventListener("load", () => {
    frame.contentWindow?.postMessage(JSON.stringify({ event: "listening", id: frame.src }), ORIGIN);
  });

  new IntersectionObserver(
    ([entry]) => {
      if (!entry.isIntersecting && state === PLAYING) {
        command(frame, "pauseVideo");
        pausedByScroll = true;
      } else if (entry.isIntersecting && pausedByScroll && state === PAUSED) {
        command(frame, "playVideo");
        pausedByScroll = false;
      }
    },
    { threshold: 0.5 },
  ).observe(card);
}

for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-short]")) {
  link.addEventListener("click", (event) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const card = link.closest<HTMLElement>("[data-short-card]");
    const frame = embed(link, { muted: false });
    if (frame && card?.hasAttribute("data-autoplay")) watch(frame, card);
  });
}

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const saveData = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection?.saveData === true;

if (!reducedMotion && !saveData && "IntersectionObserver" in window) {
  for (const card of document.querySelectorAll<HTMLElement>("[data-short-card][data-autoplay]")) {
    const start = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return;
        start.disconnect();
        const link = card.querySelector<HTMLAnchorElement>("a[data-short]");
        const frame = link && embed(link, { muted: true });
        if (frame) watch(frame, card);
      },
      { threshold: 0.5 },
    );
    start.observe(card);
  }
}
