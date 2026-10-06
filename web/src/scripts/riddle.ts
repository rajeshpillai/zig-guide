/**
 * Plays a riddle short inside its card instead of sending the reader away.
 *
 * Every `a[data-short]` is a working link to YouTube in the markup, so with
 * JavaScript off it still opens the video. With it on, a plain click swaps the
 * card's body for a youtube-nocookie player. Nothing from YouTube is requested
 * before that click, which is what the privacy page promises. A click with a
 * modifier key, or a middle click, is left alone so "open in new tab" works.
 */
function play(link: HTMLAnchorElement, event: MouseEvent) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const id = link.dataset.short;
  const card = link.closest<HTMLElement>("[data-short-card]");
  if (!id || !card) return;
  event.preventDefault();

  const frame = document.createElement("iframe");
  frame.className = "riddle-player";
  frame.src = `https://www.youtube-nocookie.com/embed/${encodeURIComponent(id)}?autoplay=1&playsinline=1&rel=0`;
  frame.title = link.dataset.title ?? "Riddle video";
  frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
  frame.allowFullscreen = true;
  frame.referrerPolicy = "strict-origin-when-cross-origin";

  card.querySelector(".riddle-play")?.replaceWith(frame);
  card.classList.add("is-playing");
}

for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-short]")) {
  link.addEventListener("click", (event) => play(link, event));
}
