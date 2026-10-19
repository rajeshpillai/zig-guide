/**
 * Paints the `.ppm` and `.png` files a graphics snippet leaves behind.
 *
 * The browser twin of `tools/picture.mjs`, which CI uses to hold each file to
 * the hash line the snippet printed. This side only has to draw the file: the
 * browser gate hashes the canvas it painted, so a parser that disagreed with
 * the Node one would fail there.
 *
 * A PNG is decoded by the browser itself, not by code on this site. The
 * Write a PNG chapter's encoder is then checked by a decoder it shares no
 * code with, which is the check a reader opening the file elsewhere would
 * make.
 */

/** Largest on-screen scale. 64x32 at 8 is 512x256, which fits the column. */
const MAX_SCALE = 8;

function isSpace(byte: number): boolean {
  return byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d;
}

/** Parse a P6 file with maxval 255, the only kind `_canvas.zig` writes. */
export function parsePpm(bytes: Uint8Array): { width: number; height: number; pixels: Uint8Array } {
  let at = 0;
  const token = () => {
    while (at < bytes.length && isSpace(bytes[at])) at++;
    const start = at;
    while (at < bytes.length && !isSpace(bytes[at])) at++;
    return String.fromCharCode(...bytes.subarray(start, at));
  };
  const magic = token();
  const width = Number(token());
  const height = Number(token());
  const maxval = Number(token());
  at++; // the single whitespace byte after maxval
  const pixels = bytes.subarray(at);
  if (magic !== "P6" || maxval !== 255 || !(width > 0 && height > 0) || pixels.length !== width * height * 3) {
    throw new Error("not a 24-bit binary PPM");
  }
  return { width, height, pixels };
}

/** Decode to a canvas at the picture's own resolution. */
async function paint(name: string, bytes: Uint8Array): Promise<HTMLCanvasElement> {
  const canvas = document.createElement("canvas");
  if (name.endsWith(".png")) {
    // No colour conversion: a PNG with no colour chunk is sRGB already, and
    // converting would move the bytes the gate compares.
    const bitmap = await createImageBitmap(new Blob([bytes as BlobPart], { type: "image/png" }), {
      colorSpaceConversion: "none",
      premultiplyAlpha: "none",
    });
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    canvas.getContext("2d")!.drawImage(bitmap, 0, 0);
    bitmap.close();
    return canvas;
  }

  const { width, height, pixels } = parsePpm(bytes);
  canvas.width = width;
  canvas.height = height;
  const image = new ImageData(width, height);
  for (let i = 0, o = 0; i < pixels.length; i += 3, o += 4) {
    image.data[o] = pixels[i];
    image.data[o + 1] = pixels[i + 1];
    image.data[o + 2] = pixels[i + 2];
    image.data[o + 3] = 255;
  }
  canvas.getContext("2d")!.putImageData(image, 0, 0);
  return canvas;
}

/**
 * One `<figure>` holding the picture at its real resolution, scaled up by CSS
 * with no smoothing so every pixel the program wrote stays a visible square.
 */
export async function pictureFigure(name: string, bytes: Uint8Array): Promise<HTMLElement> {
  const figure = document.createElement("figure");
  figure.className = "pg-picture";

  const caption = document.createElement("figcaption");
  try {
    const canvas = await paint(name, bytes);
    canvas.dataset.name = name;
    canvas.style.maxWidth = `${canvas.width * MAX_SCALE}px`;
    canvas.setAttribute("role", "img");
    canvas.setAttribute(
      "aria-label",
      `${name}, ${canvas.width} by ${canvas.height} pixels, drawn by the program`,
    );
    caption.textContent = `${name} · ${canvas.width}×${canvas.height}`;
    figure.append(canvas, caption);
  } catch (err) {
    caption.textContent = `${name}: ${err instanceof Error ? err.message : String(err)}`;
    figure.append(caption);
  }
  return figure;
}
