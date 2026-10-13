// Reading the pictures a snippet leaves in its working directory.
//
// A graphics snippet writes a binary PPM (P6) and prints one line for it:
//
//   wrote triangle.ppm: 64x32, fnv1a d62c1083
//
// `snippets/09-graphics/_canvas.zig` writes both. The hash is FNV-1a over the
// pixel bytes only, not the header, so the browser gate can recompute it from
// the canvas it painted and land on the same number. `run-wasi.mjs` holds the
// file to the line, `.expected` holds the line, and between them the picture is
// as checked as the text.

/** Parse a P6 file with maxval 255. Throws on anything else. */
export function parsePpm(bytes) {
  // Header: magic, width, height, maxval, separated by whitespace, then exactly
  // one whitespace byte before the pixels. `_canvas.zig` never writes comments,
  // so a `#` here means someone else wrote the file.
  let at = 0;
  const token = () => {
    while (at < bytes.length && /\s/.test(String.fromCharCode(bytes[at]))) at++;
    const start = at;
    while (at < bytes.length && !/\s/.test(String.fromCharCode(bytes[at]))) at++;
    return String.fromCharCode(...bytes.subarray(start, at));
  };
  const magic = token();
  const width = Number(token());
  const height = Number(token());
  const maxval = Number(token());
  at++; // the single whitespace byte after maxval
  if (magic !== "P6") throw new Error(`not a P6 PPM (magic ${JSON.stringify(magic)})`);
  if (!(width > 0 && height > 0)) throw new Error(`bad size ${width}x${height}`);
  if (maxval !== 255) throw new Error(`maxval ${maxval}, expected 255`);
  const pixels = bytes.subarray(at);
  if (pixels.length !== width * height * 3) {
    throw new Error(`${pixels.length} pixel bytes, expected ${width * height * 3} for ${width}x${height}`);
  }
  return { width, height, pixels };
}

/** FNV-1a, 32 bits, as `std.hash.Fnv1a_32`. Lowercase hex, eight digits. */
export function fnv1a32(bytes) {
  let h = 0x811c9dc5;
  for (const b of bytes) h = Math.imul(h ^ b, 0x01000193) >>> 0;
  return h.toString(16).padStart(8, "0");
}

/** The line a snippet must print for a picture it wrote. */
export function pictureLine(name, { width, height, pixels }) {
  return `wrote ${name}: ${width}x${height}, fnv1a ${fnv1a32(pixels)}`;
}
