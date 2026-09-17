// The graphics panel's pure half: how a sprite's bytes decode into pixels,
// and how a sheet of sprites is exported -- packed into one picture, described
// by a JSON atlas, and written out again as assembler source -- and read back.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node tests/graphics_model_test.js). The page gets it inlined as source:
// showGraphicsPanel() puts this whole file where graphics_view.html has its
// marker, which is why nothing here may use require() and why the export at
// the bottom is guarded.

'use strict';

// The ULA's own palette, so a sprite here is the colour it will be on the
// screen panel: two-thirds brightness for normal, full for bright, and
// black identical in both halves because the Spectrum's is.
const PALETTE = [
  [0, 0, 0], [0, 0, 192], [192, 0, 0], [192, 0, 192],
  [0, 192, 0], [0, 192, 192], [192, 192, 0], [192, 192, 192],
  [0, 0, 0], [0, 0, 255], [255, 0, 0], [255, 0, 255],
  [0, 255, 0], [0, 255, 255], [255, 255, 0], [255, 255, 255]
];
const COLOUR_NAMES = ['black', 'blue', 'red', 'magenta', 'green', 'cyan', 'yellow', 'white'];

const BITMAP_BYTES = 6144;
const ATTR_BYTES = 768;

// What defines one sprite, as opposed to how the sheet is displayed. The
// dialog edits exactly this, which is why a sprite keeps its own size,
// format, mask arrangement and colours while zoom and grid stay global.
//
// `group` is the panel's id for the group the sprite is in ('' for none). The
// model only ever sees a group by name, as `groupName` on the entries it is
// handed, so renaming a group never has to touch its sprites.
const SPRITE_KEYS = ['name', 'group', 'source', 'address', 'file', 'offset', 'format', 'width',
                     'height', 'count', 'columns', 'header', 'first', 'interleave', 'invertMask',
                     'bottomUp', 'ink', 'paper'];

const DRAFT_DEFAULTS = {
  name: '', group: '',
  source: 'memory', address: '$4000', file: undefined, offset: 0,
  format: 'screen',
  width: 2, height: 16, count: 16, columns: 8, header: 0, first: 32,
  interleave: 'none', invertMask: false, bottomUp: false,
  ink: 0, paper: 15
};

function spriteConfig(from) {
  const cfg = {};
  for (const key of SPRITE_KEYS) {
    cfg[key] = from[key];
  }
  return cfg;
}

// A sprite's settings with anything missing filled in from the defaults --
// a sprite kept by an older panel, or a partial view from outside, must
// not turn into blank boxes.
function withDefaults(from) {
  const cfg = Object.assign({}, DRAFT_DEFAULTS);
  for (const key of SPRITE_KEYS) {
    if (from[key] !== undefined && from[key] !== null) {
      cfg[key] = from[key];
    }
  }
  return cfg;
}

// ---- decoding ----------------------------------------------------------------
//
// Parameterised by config and bytes rather than reading one global pair,
// because the whole point of the sheet is that each sprite has its own.

function bytesPerRow(cfg) {
  return cfg.width * (cfg.interleave === 'none' ? 1 : 2);
}

function bytesPerItem(cfg) {
  return cfg.header + bytesPerRow(cfg) * cfg.height;
}

function bytesWanted(cfg) {
  if (cfg.format === 'screen') {
    return BITMAP_BYTES + ATTR_BYTES;
  }
  return Math.max(1, bytesPerItem(cfg) * cfg.count);
}

function itemCount(cfg) {
  return cfg.format === 'screen' ? 1 : Math.max(1, cfg.count);
}

function itemPixelSize(cfg) {
  if (cfg.format === 'screen') {
    return { w: 256, h: 192 };
  }
  return { w: cfg.width * 8, h: cfg.height };
}

// Where in the supplied bytes the given pixel of the given item lives, and
// which bit of it. Returns null when the data ran out, which is normal:
// the count is a guess until you have seen the picture.
function locate(cfg, bytes, item, x, y) {
  const row = cfg.bottomUp ? cfg.height - 1 - y : y;
  const byteCol = x >> 3;
  const stride = cfg.interleave === 'none' ? 1 : 2;
  const base = item * bytesPerItem(cfg) + cfg.header + row * bytesPerRow(cfg)
               + byteCol * stride;
  const dataAt = cfg.interleave === 'md' ? base + 1 : base;
  const maskAt = cfg.interleave === 'md' ? base : cfg.interleave === 'dm' ? base + 1 : -1;
  if (dataAt >= bytes.length || (maskAt >= 0 && maskAt >= bytes.length)) {
    return null;
  }
  return { dataAt, maskAt, bit: 7 - (x & 7) };
}

// A pixel is one of three things, and the mask decides which two are on
// offer: with no mask every pixel is ink or paper, and with one, a masked
// pixel is transparent whatever its data bit says.
function pixelKind(cfg, bytes, item, x, y) {
  const at = locate(cfg, bytes, item, x, y);
  if (!at) {
    return { kind: 'missing' };
  }
  let masked = false;
  if (at.maskAt >= 0) {
    const maskByte = cfg.invertMask ? bytes[at.maskAt] ^ 0xFF : bytes[at.maskAt];
    masked = (maskByte >> at.bit & 1) === 1;
  }
  const set = (bytes[at.dataAt] >> at.bit & 1) === 1;
  return { kind: masked ? 'clear' : set ? 'ink' : 'paper', at };
}

// The display file's famous scramble: y = 0bYYyyyxxx maps to
// 0b010YY xxx yyy, so consecutive addresses walk down eight-line bands
// rather than down the screen.
function screenOffset(x, y) {
  const third = (y >> 6) & 3;
  const line = (y >> 3) & 7;
  const row = y & 7;
  return (third << 11) | (row << 8) | (line << 5) | (x >> 3);
}

// One item as RGBA into `out` (width * height * 4, sized by itemPixelSize).
// Masked pixels and pixels past the end of the data are fully transparent.
// Returns whether the data ran out part way.
function renderItem(cfg, bytes, index, out) {
  if (cfg.format === 'screen') {
    return renderScreen(cfg, bytes, out);
  }
  const size = itemPixelSize(cfg);
  let short = false;
  for (let y = 0; y < size.h; y++) {
    for (let x = 0; x < size.w; x++) {
      const p = pixelKind(cfg, bytes, index, x, y);
      const at = (y * size.w + x) * 4;
      if (p.kind === 'clear' || p.kind === 'missing') {
        out[at] = out[at + 1] = out[at + 2] = out[at + 3] = 0;
        if (p.kind === 'missing') {
          short = true;
        }
        continue;
      }
      const rgb = PALETTE[(p.kind === 'ink' ? cfg.ink : cfg.paper) & 15];
      out[at] = rgb[0];
      out[at + 1] = rgb[1];
      out[at + 2] = rgb[2];
      out[at + 3] = 255;
    }
  }
  return short;
}

// Screen mode reads its own colours out of the attribute area when there
// is one. A 6144-byte .scr has no attributes, so it falls back to the ink
// and paper pickers -- which is why they stay meaningful here.
function renderScreen(cfg, bytes, out) {
  const haveAttrs = bytes.length >= BITMAP_BYTES + ATTR_BYTES;
  let short = false;
  for (let y = 0; y < 192; y++) {
    for (let x = 0; x < 256; x++) {
      const at = (y * 256 + x) * 4;
      const offset = screenOffset(x, y);
      if (offset >= bytes.length) {
        out[at] = out[at + 1] = out[at + 2] = out[at + 3] = 0;
        short = true;
        continue;
      }
      const set = (bytes[offset] >> (7 - (x & 7)) & 1) === 1;
      let ink = cfg.ink;
      let paper = cfg.paper;
      if (haveAttrs) {
        const attr = bytes[BITMAP_BYTES + (y >> 3) * 32 + (x >> 3)];
        const bright = (attr & 0x40) ? 8 : 0;
        ink = (attr & 7) | bright;
        paper = ((attr >> 3) & 7) | bright;
      }
      const rgb = PALETTE[(set ? ink : paper) & 15];
      out[at] = rgb[0];
      out[at + 1] = rgb[1];
      out[at + 2] = rgb[2];
      out[at + 3] = 255;
    }
  }
  return short;
}

function labelText(cfg, index) {
  if (cfg.format !== 'font') {
    return '#' + index;
  }
  const code = (cfg.first + index) & 0xFF;
  const printable = code >= 32 && code < 127 ? String.fromCharCode(code) : '';
  return code + (printable ? " '" + printable + "'" : '');
}

function hex(value, digits) {
  return '$' + value.toString(16).toUpperCase().padStart(digits, '0');
}

function fileLeafOf(path) {
  const cut = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
  return cut >= 0 ? path.slice(cut + 1) : (path || 'file');
}

// ---- names ---------------------------------------------------------------------
//
// One name serves as the atlas's frame key and the assembler label, so it has
// to be a valid label: letters, digits and underscores, not starting with a
// digit.

function sanitizeLabel(text) {
  let label = String(text || '').replace(/[^A-Za-z0-9_]+/g, '_').replace(/^_+|_+$/g, '');
  if (/^[0-9]/.test(label)) {
    label = '_' + label;
  }
  return label;
}

// What a sprite is called when nobody named it: the symbol it was read from,
// the file and offset it came out of, or else what it is.
function suggestedBaseName(cfg) {
  const address = String(cfg.address || '').trim();
  if (cfg.source === 'memory' && /^[A-Za-z_]/.test(address)) {
    const label = sanitizeLabel(address);
    if (label) {
      return label;
    }
  }
  if (cfg.source === 'file' && cfg.file) {
    const leaf = fileLeafOf(cfg.file).replace(/\.[^.]*$/, '');
    const label = sanitizeLabel(leaf + '_' + (cfg.offset || 0));
    if (label) {
      return label;
    }
  }
  return cfg.format === 'font' ? 'font' : cfg.format === 'screen' ? 'screen' : 'sprite';
}

// A name for a new sprite that no other sprite in `taken` has: the suggested
// base as it is when that is free, numbered otherwise -- and always numbered
// when the base is only a kind (sprite1, sprite2), since a bare "sprite" says
// nothing.
function suggestName(cfg, taken) {
  const base = suggestedBaseName(cfg);
  const generic = base === 'sprite' || base === 'font' || base === 'screen';
  if (!generic && !taken.has(base)) {
    return base;
  }
  for (let n = generic ? 1 : 2; ; n++) {
    const name = base + (generic ? '' : '_') + n;
    if (!taken.has(name)) {
      return name;
    }
  }
}

function defaultBaseName(entry) {
  const base = suggestedBaseName(entry);
  return base === 'sprite' || base === 'font' || base === 'screen' ? base + entry.id : base;
}

// The label a sprite's own name makes: prefixed with its group's, so a
// "walk" in the group "knight" and a "walk" in "guard" stay apart.
function spriteLabel(entry) {
  const own = sanitizeLabel(entry.name) || defaultBaseName(entry);
  const group = sanitizeLabel(entry.groupName);
  return group ? group + '_' + own : own;
}

// The frame (and label) for one item of a sprite: the sprite's own name when
// it is a single picture, its character code in a font, its index otherwise.
function frameName(cfg, base, index) {
  if (cfg.format === 'screen' || itemCount(cfg) === 1) {
    return base;
  }
  if (cfg.format === 'font') {
    return base + '_' + ((cfg.first + index) & 0xFF);
  }
  return base + '_' + index;
}

// Items that have any bytes at all. A count set higher than the data runs is
// normal while exploring; the export leaves out what would be empty frames.
function presentItems(cfg, bytes) {
  const items = [];
  if (cfg.format === 'screen') {
    if (bytes.length > 0) {
      items.push(0);
    }
    return items;
  }
  const per = bytesPerItem(cfg);
  for (let index = 0; index < itemCount(cfg); index++) {
    if (index * per + cfg.header < bytes.length) {
      items.push(index);
    }
  }
  return items;
}

// A label for every sprite, unique across every label the export will write.
// A sprite named "ball" with two items writes ball, ball_0 and ball_1, so a
// second sprite named "ball_1" has to become something else. Group labels
// are taken first: each marks where its group's data starts.
function assignNames(entries) {
  const used = new Set();
  const names = new Map();
  for (const entry of entries) {
    const group = sanitizeLabel(entry.groupName);
    if (group) {
      used.add(group);
    }
  }
  for (const entry of entries) {
    const base = spriteLabel(entry);
    const count = itemCount(entry);
    for (let n = 1; ; n++) {
      const candidate = n === 1 ? base : base + '_' + n;
      const labels = [candidate];
      if (count > 1 || entry.format === 'screen') {
        for (let index = 0; index < count; index++) {
          labels.push(frameName(entry, candidate, index));
        }
      }
      if (entry.format === 'screen') {
        labels.push(candidate + '_bitmap', candidate + '_attrs');
      }
      if (labels.every((label) => !used.has(label))) {
        for (const label of labels) {
          used.add(label);
        }
        names.set(entry.id, candidate);
        break;
      }
    }
  }
  return names;
}

// ---- packing -------------------------------------------------------------------

const EXPORT_PAD = 1;
const EXPORT_WRAP = 512;

// Lays the sprites out on one picture at one pixel per Spectrum pixel: each
// sprite as a block keeping its own columns, blocks in sheet order along
// shelves that wrap at a fixed width (or the widest block, if wider), and each
// group starting a shelf of its own. One pixel between everything, so an
// engine that filters the picture never bleeds one frame into the next.
function packSheet(entries, bytesById, names) {
  const frames = [];
  const skipped = [];
  const blocks = [];
  let wrap = EXPORT_WRAP;
  for (const entry of entries) {
    const bytes = bytesById.get(entry.id) || new Uint8Array(0);
    const items = presentItems(entry, bytes);
    if (items.length === 0) {
      skipped.push(entry.id);
      continue;
    }
    const size = itemPixelSize(entry);
    const columns = entry.format === 'screen'
      ? 1
      : Math.max(1, Math.min(entry.columns || 1, items.length));
    const rows = Math.ceil(items.length / columns);
    const block = {
      entry, items, size, columns,
      w: columns * size.w + (columns - 1) * EXPORT_PAD,
      h: rows * size.h + (rows - 1) * EXPORT_PAD
    };
    wrap = Math.max(wrap, block.w);
    blocks.push(block);
  }

  let x = 0;
  let y = 0;
  let shelf = 0;
  let width = 0;
  let group;
  for (const block of blocks) {
    const newGroup = block !== blocks[0] && (block.entry.groupName || '') !== group;
    group = block.entry.groupName || '';
    if (x > 0 && (x + block.w > wrap || newGroup)) {
      x = 0;
      y += shelf + EXPORT_PAD;
      shelf = 0;
    }
    const base = names.get(block.entry.id);
    block.items.forEach((index, n) => {
      frames.push({
        name: frameName(block.entry, base, index),
        id: block.entry.id,
        index,
        x: x + (n % block.columns) * (block.size.w + EXPORT_PAD),
        y: y + Math.floor(n / block.columns) * (block.size.h + EXPORT_PAD),
        w: block.size.w,
        h: block.size.h
      });
    });
    x += block.w + EXPORT_PAD;
    shelf = Math.max(shelf, block.h);
    width = Math.max(width, x - EXPORT_PAD);
  }
  const height = blocks.length ? y + shelf : 0;
  return { width, height, frames, skipped };
}

// The whole picture as RGBA, for the page to put on a canvas and encode.
function renderSheet(entries, bytesById, pack) {
  const rgba = new Uint8ClampedArray(pack.width * pack.height * 4);
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  for (const frame of pack.frames) {
    const entry = byId.get(frame.id);
    const bytes = bytesById.get(frame.id) || new Uint8Array(0);
    const item = new Uint8ClampedArray(frame.w * frame.h * 4);
    renderItem(entry, bytes, frame.index, item);
    for (let row = 0; row < frame.h; row++) {
      const from = row * frame.w * 4;
      rgba.set(item.subarray(from, from + frame.w * 4), ((frame.y + row) * pack.width + frame.x) * 4);
    }
  }
  return rgba;
}

// ---- the atlas -------------------------------------------------------------------

function toBase64(bytes) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(text);
}

function fromBase64(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

// The bytes a sprite actually covers: its items (headers included), or the
// display file and attributes for a screen, cut to what was read.
function spriteBytes(entry, bytes) {
  const wanted = entry.format === 'screen' ? BITMAP_BYTES + ATTR_BYTES : bytesWanted(entry);
  return bytes.subarray(0, Math.min(bytes.length, wanted));
}

function itemByteOffset(entry, index) {
  return entry.format === 'screen' ? 0 : index * bytesPerItem(entry);
}

// TexturePacker's "JSON (Hash)" layout, which Aseprite also writes and
// Phaser loads as it is: a `frames` object keyed by name, and `meta`. Engines
// ignore keys they do not know, so the rest rides along under `zx`: per frame,
// which sprite, group and bytes it is; in `meta.zx`, the groups, and every
// sprite's settings and where it was read from -- enough for the panel to put
// the same sheet back.
//
// options.image     the picture's file name, or null when there is no picture:
//                   the frames then have no rectangles, and the atlas is only
//                   a description of where the bytes are
// options.reference when true, a sprite read from memory or a file does not
//                   carry its bytes; it names where they are instead (see
//                   addSnapshotPointers). A sprite from a selection has
//                   nowhere else to be read from, and one in the ROM is not in
//                   a snapshot, so those always carry their own.
function buildAtlas(entries, bytesById, originById, names, pack, options) {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const image = options.image || null;
  const frames = {};
  for (const frame of pack.frames) {
    const entry = byId.get(frame.id);
    const origin = originById.get(frame.id);
    const offset = itemByteOffset(entry, frame.index);
    const zx = { sprite: names.get(frame.id), item: frame.index, offset };
    if (entry.groupName) {
      zx.group = entry.groupName;
    }
    if (entry.format === 'font') {
      zx.code = (entry.first + frame.index) & 0xFF;
    }
    if (origin && origin.kind === 'memory' && typeof origin.address === 'number') {
      zx.address = (origin.address + offset) & 0xFFFF;
    }
    const size = { w: frame.w, h: frame.h };
    frames[frame.name] = image
      ? {
          frame: { x: frame.x, y: frame.y, w: frame.w, h: frame.h },
          rotated: false,
          trimmed: false,
          spriteSourceSize: { x: 0, y: 0, w: frame.w, h: frame.h },
          sourceSize: size,
          zx
        }
      : { sourceSize: size, zx };
  }

  const sprites = [];
  const groups = [];
  for (const entry of entries) {
    if (pack.skipped.includes(entry.id)) {
      continue;
    }
    const origin = originById.get(entry.id);
    const bytes = spriteBytes(entry, bytesById.get(entry.id) || new Uint8Array(0));
    const sprite = spriteConfig(entry);
    sprite.name = sanitizeLabel(entry.name) || defaultBaseName(entry);
    sprite.label = names.get(entry.id);
    delete sprite.group;
    if (entry.groupName) {
      sprite.group = entry.groupName;
      let group = groups.find((g) => g.name === entry.groupName);
      if (!group) {
        group = { name: entry.groupName, sprites: [], frames: [] };
        groups.push(group);
      }
      group.sprites.push(sprite.label);
    }
    if (sprite.source !== 'file') {
      delete sprite.file;
      delete sprite.offset;
    }
    if (sprite.source !== 'memory') {
      delete sprite.address;
    }
    if (origin && origin.label) {
      sprite.origin = origin.label;
    }
    if (origin && origin.kind === 'memory' && typeof origin.address === 'number') {
      sprite.resolvedAddress = origin.address;
    }
    sprite.frames = pack.frames.filter((f) => f.id === entry.id).map((f) => f.name);
    sprite.length = bytes.length;
    if (!options.reference || !canPoint(sprite)) {
      sprite.bytes = toBase64(bytes);
    }
    for (const group of groups) {
      if (group.name === entry.groupName) {
        group.frames.push(...sprite.frames);
      }
    }
    sprites.push(sprite);
  }

  const meta = { app: 'ZX Spectrum emulator graphics viewer', version: '1.0' };
  if (image) {
    Object.assign(meta, {
      image,
      format: 'RGBA8888',
      size: { w: pack.width, h: pack.height },
      scale: '1'
    });
  }
  meta.zx = { version: 1, groups, sprites };
  return { frames, meta };
}

// Whether a sprite's bytes can be found again without carrying them: in a
// file it came from, or in a snapshot of RAM.
function canPoint(sprite) {
  if (sprite.source === 'file') {
    return true;
  }
  return sprite.source === 'memory' && Number.isInteger(sprite.resolvedAddress)
      && sprite.resolvedAddress >= 0x4000 && sprite.resolvedAddress + sprite.length <= 0x10000;
}

// For an atlas that points rather than carries: gives every sprite without
// bytes a `snapshot` -- { file, offset, address } -- when its bytes are in
// one. `machine` is the snapshot saved beside the atlas ({ file, size }, or
// null); a sprite from memory points into that. A sprite from a file that is a
// .sna points into that file, with the address its bytes load at; any other
// file is pointed at by the sprite's own file and offset. `fileSize(path)`
// answers for the files, or null. Returns the labels of sprites left with
// neither bytes nor anywhere to read them from.
function addSnapshotPointers(sprites, machine, fileSize) {
  const lost = [];
  for (const sprite of sprites) {
    if (typeof sprite.bytes === 'string') {
      continue;
    }
    if (sprite.source === 'memory') {
      const offset = machine ? snaOffsetOf(sprite.resolvedAddress, machine.size) : null;
      if (offset === null) {
        lost.push(sprite.label || sprite.name);
        continue;
      }
      sprite.snapshot = { file: machine.file, offset, address: sprite.resolvedAddress };
    } else if (sprite.source === 'file' && /\.sna$/i.test(sprite.file || '')) {
      const address = snaAddressOf(sprite.offset || 0, fileSize(sprite.file) || 0);
      if (address !== null) {
        sprite.snapshot = { file: sprite.file, offset: sprite.offset || 0, address };
      }
    }
  }
  return lost;
}

// The bytes an atlas sprite points at, read with `readFile(path)` (a
// Uint8Array or Buffer), or null when it points nowhere.
function pointedBytes(sprite, readFile) {
  const length = Number.isInteger(sprite.length) ? sprite.length
               : bytesWanted(withDefaults(sprite));
  let file;
  let offset;
  if (sprite.snapshot && typeof sprite.snapshot.file === 'string') {
    file = sprite.snapshot.file;
    offset = sprite.snapshot.offset;
  } else if (sprite.source === 'file' && typeof sprite.file === 'string') {
    file = sprite.file;
    offset = sprite.offset;
  } else {
    return null;
  }
  const data = readFile(file);
  const start = Math.max(0, Math.min(Number(offset) || 0, data.length));
  return data.subarray(start, start + length);
}

// Where a Z80 address is in a .sna, and the other way round. A .sna is a
// 27-byte header and then RAM from $4000 -- on a 128K, the three pages paged
// in when it was saved, with the rest after -- so the first 48K map straight
// through. Both return null for anything outside that.
const SNA_HEADER = 27;
const SNA_48K_SIZE = SNA_HEADER + 0xC000;

function snaOffsetOf(address, fileSize) {
  if (fileSize < SNA_48K_SIZE || address < 0x4000 || address > 0xFFFF) {
    return null;
  }
  return SNA_HEADER + address - 0x4000;
}

function snaAddressOf(offset, fileSize) {
  if (fileSize < SNA_48K_SIZE || offset < SNA_HEADER || offset >= SNA_48K_SIZE) {
    return null;
  }
  return offset - SNA_HEADER + 0x4000;
}

// ---- assembler source -------------------------------------------------------------

function bin8(value) {
  return '%' + value.toString(2).padStart(8, '0');
}

function describeSprite(entry, origin) {
  const where = origin && origin.label ? origin.label
              : entry.source === 'memory' ? 'memory ' + entry.address
              : entry.source === 'file' ? fileLeafOf(entry.file || '') + ' +' + (entry.offset || 0)
              : 'a selection';
  if (entry.format === 'screen') {
    return where + ', a screen';
  }
  const parts = [where, entry.width + ' bytes x ' + entry.height + ' rows x ' + entry.count];
  if (entry.format === 'font') {
    parts.push('a font from code ' + entry.first);
  }
  if (entry.header) {
    parts.push(entry.header + ' header byte' + (entry.header === 1 ? '' : 's') + ' each');
  }
  if (entry.interleave === 'md') {
    parts.push('mask then data' + (entry.invertMask ? ', mask inverted' : ''));
  } else if (entry.interleave === 'dm') {
    parts.push('data then mask' + (entry.invertMask ? ', mask inverted' : ''));
  }
  if (entry.bottomUp) {
    parts.push('bottom row first');
  }
  return parts.join(', ');
}

// How one row of the picture looks, for the comment beside its bytes:
// # ink, . paper, a space where the mask makes a hole.
function rowPicture(entry, bytes, index, y) {
  let text = '';
  for (let x = 0; x < entry.width * 8; x++) {
    const kind = pixelKind(entry, bytes, index, x, y).kind;
    text += kind === 'ink' ? '#' : kind === 'paper' ? '.' : ' ';
  }
  return '|' + text + '|';
}

const ASM_INDENT = '\t\tDEFB\t';

function asmItem(lines, entry, bytes, index, label) {
  const per = bytesPerItem(entry);
  const start = index * per;
  const row = bytesPerRow(entry);
  lines.push(label + ':');
  if (entry.header) {
    const head = Array.from(bytes.subarray(start, start + entry.header), (b) => hex(b, 2));
    if (head.length) {
      lines.push(ASM_INDENT + head.join(',') + '\t\t; header');
    }
  }
  for (let r = 0; r < entry.height; r++) {
    const from = start + entry.header + r * row;
    const chunk = bytes.subarray(from, Math.min(from + row, bytes.length));
    if (chunk.length === 0) {
      lines.push('\t\t; the data ran out here');
      return;
    }
    const y = entry.bottomUp ? entry.height - 1 - r : r;
    let line = ASM_INDENT + Array.from(chunk, bin8).join(',');
    if (chunk.length === row) {
      line += '\t\t; ' + rowPicture(entry, bytes, index, y);
    } else {
      line += '\t\t; the data ran out here';
    }
    lines.push(line);
    if (chunk.length < row) {
      return;
    }
  }
}

function asmScreen(lines, bytes, base) {
  lines.push(base + ':');
  lines.push(base + '_bitmap:');
  for (let at = 0; at < Math.min(bytes.length, BITMAP_BYTES); at += 32) {
    const end = Math.min(at + 32, BITMAP_BYTES, bytes.length);
    lines.push(ASM_INDENT + Array.from(bytes.subarray(at, end), (b) => hex(b, 2)).join(','));
  }
  if (bytes.length > BITMAP_BYTES) {
    lines.push(base + '_attrs:');
    for (let at = BITMAP_BYTES; at < bytes.length; at += 32) {
      const end = Math.min(at + 32, bytes.length);
      lines.push(ASM_INDENT + Array.from(bytes.subarray(at, end), (b) => hex(b, 2)).join(','));
    }
  }
}

// sjasmplus source for the same sprites, byte for byte as they were read and
// in their original order -- mask bytes where they were, bottom row first if
// that is how the data runs -- so it assembles back to exactly what was there.
// Rows are written in binary with a picture of the row beside them; a screen
// is written in hex, 32 bytes to a line, since a row of it is 256 pixels.
function buildAsm(entries, bytesById, originById, names, pack, files) {
  const lines = [];
  const kept = entries.filter((entry) => !pack.skipped.includes(entry.id));
  lines.push('; ' + kept.length + ' sprite' + (kept.length === 1 ? '' : 's') +
             ' exported from the ZX Spectrum graphics viewer.');
  if (files.image) {
    lines.push('; ' + files.image + ' is the same sprites as a picture, and ' + files.atlas +
               ' says where each one is.');
  } else {
    lines.push('; ' + files.atlas + ' says what each one is and where its bytes came from.');
  }
  lines.push('; Every byte is as it was read, in its original order, so this assembles back');
  lines.push('; to the same data. Row pictures: # ink, . paper, space where the mask is clear.');
  let group = '';
  for (const entry of kept) {
    const bytes = spriteBytes(entry, bytesById.get(entry.id) || new Uint8Array(0));
    const base = names.get(entry.id);
    if ((entry.groupName || '') !== group) {
      group = entry.groupName || '';
      if (group) {
        const members = kept.filter((e) => e.groupName === group).length;
        lines.push('');
        lines.push('; ==== ' + group + ': ' + members + ' sprite' + (members === 1 ? '' : 's'));
        lines.push(sanitizeLabel(group) + ':');
      }
    }
    lines.push('');
    lines.push('; ---- ' + base + ': ' + describeSprite(entry, originById.get(entry.id)));
    if (entry.format === 'screen') {
      asmScreen(lines, bytes, base);
      continue;
    }
    const items = presentItems(entry, bytes);
    if (itemCount(entry) === 1) {
      asmItem(lines, entry, bytes, 0, base);
      continue;
    }
    lines.push(base + ':');
    for (const index of items) {
      if (entry.format === 'font') {
        lines.push('; ' + labelText(entry, index));
      }
      asmItem(lines, entry, bytes, index, frameName(entry, base, index));
    }
  }
  return lines.join('\n') + '\n';
}

// ---- reading an export back ---------------------------------------------------------

const SOURCES = ['memory', 'file', 'selection'];
const FORMATS = ['sprite', 'font', 'screen'];
const INTERLEAVES = ['none', 'md', 'dm'];
const LIMITS = {
  offset: [0, 0x7FFFFFFF], width: [1, 64], height: [1, 256], count: [1, 1024],
  columns: [1, 64], header: [0, 64], first: [0, 255], ink: [0, 15], paper: [0, 15]
};

function clampInt(value, range, fallback) {
  const number = Math.floor(Number(value));
  if (!Number.isFinite(number)) {
    return fallback;
  }
  return Math.max(range[0], Math.min(range[1], number));
}

// The sprites in an exported atlas, checked field by field: a JSON file is
// something a person may have edited, and one bad field should cost that
// field, not the sheet. Returns { sprites, groups, problems }: the group names
// in order, and the sprites, each with a `cfg.group` holding its group's name
// ('' for none), and each a
// config, the bytes it was exported with (a Uint8Array, maybe empty), and an
// origin -- a memory one, with the address it was read from, when there was one.
function readAtlas(atlas) {
  const problems = [];
  const zx = atlas && atlas.meta && atlas.meta.zx;
  if (!zx || !Array.isArray(zx.sprites)) {
    return { sprites: [], groups: [],
             problems: ['This is not a sheet exported from the graphics viewer.'] };
  }
  const sprites = [];
  // The atlas's own group order first, then any a sprite names that it lacks.
  const groups = [];
  for (const group of Array.isArray(zx.groups) ? zx.groups : []) {
    const name = sanitizeLabel(group && group.name);
    if (name && !groups.includes(name)) {
      groups.push(name);
    }
  }
  zx.sprites.forEach((raw, n) => {
    if (!raw || typeof raw !== 'object') {
      problems.push('Sprite ' + (n + 1) + ' is not an object.');
      return;
    }
    const cfg = withDefaults({});
    cfg.name = sanitizeLabel(raw.name);
    cfg.group = sanitizeLabel(raw.group);
    if (cfg.group && !groups.includes(cfg.group)) {
      groups.push(cfg.group);
    }
    cfg.source = SOURCES.includes(raw.source) ? raw.source : 'selection';
    cfg.format = FORMATS.includes(raw.format) ? raw.format : 'sprite';
    cfg.interleave = INTERLEAVES.includes(raw.interleave) ? raw.interleave : 'none';
    cfg.invertMask = raw.invertMask === true;
    cfg.bottomUp = raw.bottomUp === true;
    for (const key of Object.keys(LIMITS)) {
      cfg[key] = clampInt(raw[key], LIMITS[key], cfg[key]);
    }
    if (typeof raw.address === 'string') {
      cfg.address = raw.address;
    }
    cfg.file = typeof raw.file === 'string' ? raw.file : undefined;
    let bytes = new Uint8Array(0);
    if (typeof raw.bytes === 'string') {
      try {
        bytes = fromBase64(raw.bytes);
      } catch (err) {
        problems.push((cfg.name || 'Sprite ' + (n + 1)) + ': its bytes are not valid base64.');
      }
    }
    if (cfg.source === 'selection' && bytes.length === 0) {
      problems.push((cfg.name || 'Sprite ' + (n + 1)) + ' came from a selection and has no bytes.');
    }
    const origin = { kind: 'import', label: typeof raw.origin === 'string' ? raw.origin : '' };
    if (cfg.source === 'memory' && Number.isInteger(raw.resolvedAddress)) {
      origin.kind = 'memory';
      origin.address = raw.resolvedAddress & 0xFFFF;
    }
    sprites.push({ cfg, bytes, origin });
  });
  return { sprites, groups, problems };
}

if (typeof module !== 'undefined') {
  module.exports = {
    PALETTE, COLOUR_NAMES, BITMAP_BYTES, ATTR_BYTES, SPRITE_KEYS, DRAFT_DEFAULTS,
    spriteConfig, withDefaults,
    bytesPerRow, bytesPerItem, bytesWanted, itemCount, itemPixelSize,
    locate, pixelKind, screenOffset, renderItem, labelText, hex, fileLeafOf,
    sanitizeLabel, suggestedBaseName, suggestName, defaultBaseName, spriteLabel, frameName,
    presentItems, assignNames, packSheet, renderSheet, toBase64, fromBase64, buildAtlas,
    snaOffsetOf, snaAddressOf, addSnapshotPointers, pointedBytes, buildAsm, readAtlas
  };
}
