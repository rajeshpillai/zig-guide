/**
 * Add a Copy button to every code block that does not already have one.
 *
 * Runnable playgrounds get theirs from the `<zig-playground>` toolbar (it has
 * to read from the editor once the reader edits), so they are skipped here.
 * Static playground frames get the button in their existing toolbar; plain
 * fenced blocks get a floating button in the corner. Progressive enhancement:
 * with JS off there is simply no button.
 */

function makeButton(text: () => string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Copy";
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text());
      button.textContent = "Copied";
    } catch {
      button.textContent = "Copy failed";
    }
    setTimeout(() => (button.textContent = "Copy"), 1500);
  });
  return button;
}

for (const pre of document.querySelectorAll<HTMLPreElement>("main pre")) {
  // The runnable playground's toolbar owns copying there; pg-output is a
  // run result, not code.
  if (pre.closest("zig-playground")) continue;
  if (pre.classList.contains("pg-output")) continue;

  const staticFrame = pre.closest(".pg-static");
  if (staticFrame) {
    const toolbar = staticFrame.querySelector(".pg-toolbar");
    if (toolbar && !toolbar.querySelector(".pg-copy")) {
      const button = makeButton(() => pre.textContent ?? "");
      button.className = "pg-copy";
      toolbar.append(button);
    }
    continue;
  }

  // Plain fenced block: wrap so the button anchors to the frame rather than
  // the horizontally scrolling content.
  const wrap = document.createElement("div");
  wrap.className = "code-copy-wrap";
  pre.replaceWith(wrap);
  const button = makeButton(() => pre.textContent ?? "");
  button.className = "code-copy";
  wrap.append(pre, button);
}
