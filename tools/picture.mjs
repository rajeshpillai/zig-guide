// Reading the pictures a snippet leaves in its working directory.
//
// A graphics snippet writes a `.ppm` or a `.png` and prints one line for it:
//
//   wrote triangle.ppm: 64x32, fnv1a d62c1083
//
// `snippets/09-graphics/_canvas.zig` prints it. The hash is FNV-1a over the
// R, G and B bytes of each pixel, and none of the file's header or
// compression, so the browser gate can recompute it from the canvas it painted
// and land on the same number. `run-wasi.mjs` holds the file to the line,
// `.expected` holds the line, and between them the picture is as checked as
// the text.
//
// The PNG decoder here is deliberately not the one the chapter teaches. A
// snippet that writes a PNG also checks it with its own reader, which proves
// only that the writer and the reader agree. This one is zlib from Node plus
// the five filters from the PNG specification, and the browser decodes the
// same file with its own decoder.
import { inflateSync } from "node:zlib";

/** Decode a `.ppm` or `.png` to `{ width, height, pixels }`, pixels as RGB. */
export function parsePicture(name, bytes) {
  if (name.endsWith(".ppm")) return parsePpm(bytes);
  if (name.endsWith(".png")) return parsePng(bytes);
  throw new Error(`not a picture: ${name}`);
}

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

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/**
 * Decode an 8-bit RGB PNG with no interlacing, which is what the chapter
 * writes. Every CRC is checked. Any other kind of PNG throws rather than being
 * half-read, since a picture this cannot decode is one CI cannot vouch for.
 */
export function parsePng(bytes) {
  if (!PNG_SIGNATURE.every((b, i) => bytes[i] === b)) throw new Error("bad PNG signature");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 8;
  let header = null;
  const idat = [];
  let ended = false;
  while (at < bytes.length) {
    const length = view.getUint32(at);
    const type = String.fromCharCode(...bytes.subarray(at + 4, at + 8));
    const data = bytes.subarray(at + 8, at + 8 + length);
    const stored = view.getUint32(at + 8 + length);
    if (crc32(bytes.subarray(at + 4, at + 8 + length)) !== stored) throw new Error(`${type}: bad CRC`);
    if (type === "IHDR") {
      header = {
        width: view.getUint32(at + 8),
        height: view.getUint32(at + 12),
        depth: data[8],
        colorType: data[9],
        interlace: data[12],
      };
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      ended = true;
      break;
    }
    at += 12 + length;
  }
  if (!header) throw new Error("no IHDR chunk");
  if (!ended) throw new Error("no IEND chunk");
  const { width, height, depth, colorType, interlace } = header;
  if (depth !== 8 || colorType !== 2 || interlace !== 0) {
    throw new Error(`only 8-bit RGB without interlacing is checked (depth ${depth}, colour type ${colorType}, interlace ${interlace})`);
  }

  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * 3;
  if (raw.length !== height * (stride + 1)) {
    throw new Error(`${raw.length} bytes of scanlines, expected ${height * (stride + 1)}`);
  }
  const pixels = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const left = i >= 3 ? pixels[y * stride + i - 3] : 0;
      const up = y > 0 ? pixels[(y - 1) * stride + i] : 0;
      const upLeft = y > 0 && i >= 3 ? pixels[(y - 1) * stride + i - 3] : 0;
      let predict;
      switch (filter) {
        case 0: predict = 0; break;
        case 1: predict = left; break;
        case 2: predict = up; break;
        case 3: predict = (left + up) >> 1; break;
        case 4: predict = paeth(left, up, upLeft); break;
        default: throw new Error(`row ${y}: unknown filter ${filter}`);
      }
      pixels[y * stride + i] = (line[i] + predict) & 0xff;
    }
  }
  return { width, height, pixels };
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
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

/** Whether a file in the working directory is a picture the playground shows. */
export function isPicture(name) {
  return name.endsWith(".ppm") || name.endsWith(".png");
}
