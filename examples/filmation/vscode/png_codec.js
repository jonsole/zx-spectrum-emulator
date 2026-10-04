// PNG in and out, for the sprite sheet editor: a picture as its width, its
// height and its pixels, four bytes each (red, green, blue, alpha), top row
// first.
//
// The editor's host holds a sheet's pixels and writes them back on Save, so
// it needs both directions, exactly: a pixel read in comes out the same. A
// browser canvas would do the decoding, but not the writing of a file the
// host can test, and not without premultiplying alpha on the way. Node's own
// zlib does the compression; this is the rest of the format.
//
// What it reads is what the sheets are: eight bits a channel, greyscale,
// RGB, palette, grey with alpha or RGBA, not interlaced. sprite_sheet.py and
// melkhior_sheets.py both write RGBA. Anything else is refused with the
// reason rather than read wrongly. What it writes is always RGBA.
//
// No vscode API, so it is tested from plain Node:
//   node examples/filmation/vscode/tests/png_codec_test.js

'use strict';

const zlib = require('zlib');

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// Bytes a pixel, by colour type, at eight bits a channel.
const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

// --- reading -----------------------------------------------------------------

function decode(buffer) {
  if (buffer.length < 8 || !buffer.subarray(0, 8).equals(SIGNATURE)) {
    throw new Error('not a PNG');
  }
  let at = 8;
  let header = null;
  let palette = null;
  let alphas = null;
  const data = [];
  while (at + 8 <= buffer.length) {
    const length = buffer.readUInt32BE(at);
    const type = buffer.toString('latin1', at + 4, at + 8);
    const body = buffer.subarray(at + 8, at + 8 + length);
    at += 12 + length;                  // length, type, body, CRC
    if (type === 'IHDR') {
      header = {
        width: body.readUInt32BE(0), height: body.readUInt32BE(4),
        depth: body[8], colour: body[9], interlace: body[12]
      };
    } else if (type === 'PLTE') {
      palette = body;
    } else if (type === 'tRNS') {
      alphas = body;
    } else if (type === 'IDAT') {
      data.push(body);
    } else if (type === 'IEND') {
      break;
    }
  }
  if (!header) throw new Error('a PNG with no header');
  if (header.depth !== 8) throw new Error(header.depth + ' bits a channel: only 8 is read');
  if (header.interlace) throw new Error('an interlaced PNG: save it without interlacing');
  const bpp = CHANNELS[header.colour];
  if (!bpp) throw new Error('PNG colour type ' + header.colour + ' is not one this reads');
  if (header.colour === 3 && !palette) throw new Error('a palette PNG with no palette');

  const raw = zlib.inflateSync(Buffer.concat(data));
  const stride = header.width * bpp;
  const rows = unfilter(raw, header.height, stride, bpp);
  const rgba = new Uint8Array(header.width * header.height * 4);
  for (let y = 0; y < header.height; y++) {
    for (let x = 0; x < header.width; x++) {
      const s = y * stride + x * bpp;
      const d = (y * header.width + x) * 4;
      let r, g, b, a;
      switch (header.colour) {
        case 0: r = g = b = rows[s]; a = 255; break;
        case 2: r = rows[s]; g = rows[s + 1]; b = rows[s + 2]; a = 255; break;
        case 3: {
          const i = rows[s];
          r = palette[i * 3]; g = palette[i * 3 + 1]; b = palette[i * 3 + 2];
          a = alphas && i < alphas.length ? alphas[i] : 255;
          break;
        }
        case 4: r = g = b = rows[s]; a = rows[s + 1]; break;
        default: r = rows[s]; g = rows[s + 1]; b = rows[s + 2]; a = rows[s + 3];
      }
      rgba[d] = r; rgba[d + 1] = g; rgba[d + 2] = b; rgba[d + 3] = a;
    }
  }
  return { width: header.width, height: header.height, rgba: rgba };
}

// Undo the per-row filters, in place in a copy: each row starts with a byte
// saying which filter it went through, and each is a prediction from the
// pixel to the left, the one above, or both.
function unfilter(raw, height, stride, bpp) {
  const out = new Uint8Array(height * stride);
  let at = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[at++];
    const row = y * stride;
    const up = row - stride;
    for (let i = 0; i < stride; i++) {
      const left = i >= bpp ? out[row + i - bpp] : 0;
      const above = y ? out[up + i] : 0;
      const corner = y && i >= bpp ? out[up + i - bpp] : 0;
      let guess;
      switch (filter) {
        case 0: guess = 0; break;
        case 1: guess = left; break;
        case 2: guess = above; break;
        case 3: guess = (left + above) >> 1; break;
        case 4: guess = paeth(left, above, corner); break;
        default: throw new Error('row ' + y + ' has filter ' + filter + ', which PNG has not got');
      }
      out[row + i] = (raw[at++] + guess) & 0xff;
    }
  }
  return out;
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

// --- writing -----------------------------------------------------------------

// RGBA, eight bits a channel, each row put through whichever filter makes it
// smallest by the usual measure -- the least sum of the bytes as signed
// numbers -- which is what keeps a mostly-black sheet as small as the one
// PIL writes.
function encode(picture) {
  const width = picture.width;
  const height = picture.height;
  const stride = width * 4;
  const filtered = Buffer.alloc(height * (stride + 1));
  const rgba = picture.rgba;
  const tries = [Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride),
                 Buffer.alloc(stride), Buffer.alloc(stride)];
  for (let y = 0; y < height; y++) {
    const row = y * stride;
    let best = 0;
    let least = Infinity;
    for (let f = 0; f < 5; f++) {
      const t = tries[f];
      let cost = 0;
      for (let i = 0; i < stride; i++) {
        const left = i >= 4 ? rgba[row + i - 4] : 0;
        const above = y ? rgba[row - stride + i] : 0;
        const corner = y && i >= 4 ? rgba[row - stride + i - 4] : 0;
        const guess = f === 0 ? 0 : f === 1 ? left : f === 2 ? above
          : f === 3 ? (left + above) >> 1 : paeth(left, above, corner);
        const v = (rgba[row + i] - guess) & 0xff;
        t[i] = v;
        cost += v < 128 ? v : 256 - v;
      }
      if (cost < least) { least = cost; best = f; }
    }
    const at = y * (stride + 1);
    filtered[at] = best;
    tries[best].copy(filtered, at + 1);
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;                        // bits a channel
  header[9] = 6;                        // RGBA
  return Buffer.concat([
    SIGNATURE,
    chunk('IHDR', header),
    chunk('IDAT', zlib.deflateSync(filtered, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

function chunk(type, body) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(body.length, 0);
  head.write(type, 4, 'latin1');
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])), 0);
  return Buffer.concat([head, body, tail]);
}

let crcTable = null;

function crc32(bytes) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

module.exports = { decode, encode, crc32 };
