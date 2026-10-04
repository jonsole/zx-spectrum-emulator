// What a Filmation sprite sheet is to the sprite sheet editor: the picture's
// pixels, the rectangles a description cuts out of it, and the edits you can
// make to them.
//
// A sheet is two files: a PNG (art/sprites.png, or a Melkhior sheet in
// art/melkhior/) and the description that names it in sheet.file
// (metadata/sprites.json, metadata/melkhior/<name>.json). The description
// holds the tree of groups and the rectangle of every sprite; the picture
// holds the pixels, four colours that mean something to the build -- ink,
// paper, transparent and the rare stray -- and a one-pixel frame in the
// border colour just outside every rectangle, which examples/filmation/scripts/
// sheet.py checks so that a rectangle that has moved off its sprite is caught.
//
// The picture here is { width, height, rgba }, rgba being four bytes a pixel,
// top row first -- what png_codec.js reads and writes, and what a canvas's
// ImageData holds.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node examples/filmation/vscode/tests/sprite_sheet_model_test.js). The page
// gets it inlined as source, which is why the export at the bottom is guarded.

'use strict';

// What each colour means, as sheet.py's PALETTE has them. A description says
// its own in sheet.colours, and these are what it means when it does not.
const DEFAULT_COLOURS = {
  ink: [255, 255, 255, 255],
  paper: [0, 0, 0, 255],
  transparent: [0, 0, 0, 0],
  stray: [255, 0, 0, 255],
  border: [255, 0, 255, 255]
};

// The four a sprite's pixel can be, in the order the editor offers them.
// Stray is a data bit under a hole in the mask: it draws nothing on its own,
// and is here because the original art has a few.
const PAINTS = ['ink', 'paper', 'transparent', 'stray'];

// sheet.py's OPAQUE: alpha at or above this is a colour, below it a hole.
const OPAQUE = 128;

// What the engine draws as one sprite -- sheet.py's NARROWEST_BYTES,
// WIDEST_BYTES and TALLEST_ROWS. The build stops on a sprite from another
// sheet outside them; the editor says so.
const NARROWEST = 16;
const WIDEST = 40;
const TALLEST = 64;

// --- the description -----------------------------------------------------------

// The order a description lists things in is the order the build lays them
// out and emits them, and a sheet can name sprites "2" before "1" -- Knight
// Lore 128K's does. A JavaScript object always lists keys that look like
// numbers first, in numeric order, whatever order they came in, so
// JSON.parse would quietly reorder them. parseSheet keeps each object's
// order in a KEYS property of its own, which survives JSON.stringify -- the
// page is sent the sheet as JSON -- and keysOf reads it.
const KEYS = '__keys';

function keysOf(object) {
  if (!object) return [];
  const own = Object.keys(object).filter((k) => k !== KEYS);
  const said = Array.isArray(object[KEYS]) ? object[KEYS].filter((k) => own.indexOf(k) >= 0) : [];
  for (const k of own) if (said.indexOf(k) < 0) said.push(k);
  return said;
}

// JSON, keeping every object's key order in KEYS. Strict enough for the
// files it reads, which a program wrote.
function parseSheet(text) {
  let at = 0;
  const fail = (why) => { throw new Error(why + ' at character ' + at); };
  const space = () => { while (at < text.length && ' \t\r\n'.indexOf(text[at]) >= 0) at++; };
  function value() {
    space();
    const c = text[at];
    if (c === '{') {
      at++;
      const out = {};
      const keys = [];
      space();
      if (text[at] === '}') { at++; out[KEYS] = keys; return out; }
      for (;;) {
        space();
        if (text[at] !== '"') fail('a name was wanted');
        const key = string();
        space();
        if (text[at++] !== ':') fail('a colon was wanted');
        out[key] = value();
        keys.push(key);
        space();
        if (text[at] === ',') { at++; continue; }
        if (text[at] === '}') { at++; break; }
        fail('a comma or } was wanted');
      }
      out[KEYS] = keys;
      return out;
    }
    if (c === '[') {
      at++;
      const out = [];
      space();
      if (text[at] === ']') { at++; return out; }
      for (;;) {
        out.push(value());
        space();
        if (text[at] === ',') { at++; continue; }
        if (text[at] === ']') { at++; break; }
        fail('a comma or ] was wanted');
      }
      return out;
    }
    if (c === '"') return string();
    const m = /^(-?\d+(\.\d+)?([eE][+-]?\d+)?|true|false|null)/.exec(text.slice(at, at + 40));
    if (!m) fail('a value was wanted');
    at += m[0].length;
    return JSON.parse(m[0]);
  }
  function string() {
    const start = at;
    at++;
    while (at < text.length && text[at] !== '"') at += text[at] === '\\' ? 2 : 1;
    at++;
    return JSON.parse(text.slice(start, at));
  }
  const out = value();
  space();
  if (at < text.length) fail('something after the end');
  return out;
}

function coloursOf(sheet) {
  const said = ((sheet && sheet.sheet) || {}).colours || {};
  const out = {};
  for (const name of Object.keys(DEFAULT_COLOURS)) {
    const rgba = said[name] || DEFAULT_COLOURS[name];
    out[name] = [rgba[0], rgba[1], rgba[2], rgba.length > 3 ? rgba[3] : 255];
  }
  return out;
}

// The groups and sprites as a tree, in the file's own order: each group
// { name, path, sprites, groups }, each sprite { name, path, rect, trim }.
// `path` is the dotted name the build and graphics.json know it by --
// sabreman.legs.1 -- without any sheet prefix.
function sheetTree(sheet) {
  function walk(node, path) {
    const out = { name: path.length ? path[path.length - 1] : '', path: path.join('.'),
                  sprites: [], groups: [] };
    for (const key of keysOf(node && node.sprites)) {
      const box = node.sprites[key];
      out.sprites.push({
        name: key,
        path: path.concat([key]).join('.'),
        rect: { x: box.x, y: box.y, w: box.w, h: box.h },
        trim: box.trim || 0
      });
    }
    for (const group of keysOf(node && node.group)) {
      out.groups.push(walk(node.group[group], path.concat([group])));
    }
    return out;
  }
  return walk(sheet || {}, []);
}

// Every sprite, flat, in the tree's order.
function allSpritesOf(tree) {
  const out = [];
  (function walk(group) {
    for (const sprite of group.sprites) out.push(sprite);
    for (const sub of group.groups) walk(sub);
  }(tree));
  return out;
}

// --- pixels --------------------------------------------------------------------

// Which of the colours a pixel is: one of PAINTS, 'border', or null for a
// colour the sheet gives no meaning. Anything see-through is transparent,
// whatever its colour, as the build reads it.
function colourAt(picture, colours, x, y) {
  const i = (y * picture.width + x) * 4;
  const d = picture.rgba;
  if (d[i + 3] < OPAQUE) return 'transparent';
  for (const name of ['ink', 'paper', 'stray', 'border']) {
    const c = colours[name];
    if (d[i] === c[0] && d[i + 1] === c[1] && d[i + 2] === c[2]) return name;
  }
  return null;
}

function setColour(picture, colours, x, y, name) {
  const i = (y * picture.width + x) * 4;
  const c = colours[name];
  picture.rgba[i] = c[0];
  picture.rgba[i + 1] = c[1];
  picture.rgba[i + 2] = c[2];
  picture.rgba[i + 3] = c[3];
}

function inside(rect, x, y) {
  return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h;
}

// A paint stroke, as the page sends it and the host keeps it for undo: the
// pixels it touched, in sheet coordinates, each with the colour it had and
// the one it was given. Only pixels inside the sprite's rectangle are
// painted -- the frame and the rest of the sheet are not the brush's -- and
// a pixel already that colour is left out, so a stroke that changed nothing
// is empty.
function paint(picture, colours, rect, points, name) {
  const changes = [];
  const seen = new Set();
  for (const p of points) {
    if (!inside(rect, p.x, p.y)) continue;
    const key = p.y * picture.width + p.x;
    if (seen.has(key)) continue;
    seen.add(key);
    const was = colourAt(picture, colours, p.x, p.y);
    if (was === name) continue;
    changes.push({ x: p.x, y: p.y, from: was, to: name });
  }
  return changes;
}

// What a press paints, from the colour under it and the one picked: a press
// on ink paints paper and one on paper paints ink, so a click toggles a pixel
// between the two -- unless Transparent is picked, which always rubs out. On
// a clear pixel, or a stray one, it is the colour picked. A stroke keeps the
// colour its first pixel gave it, so dragging from ink turns ink to paper
// all the way along.
function strokeColour(under, picked) {
  if (picked === 'transparent') return 'transparent';
  if (under === 'ink') return 'paper';
  if (under === 'paper') return 'ink';
  return picked;
}

// The pixels a fill from one point would change: every pixel of the same
// colour joined to it along a side, within the sprite's rectangle.
function fill(picture, colours, rect, x, y, name) {
  if (!inside(rect, x, y)) return [];
  const was = colourAt(picture, colours, x, y);
  if (was === name) return [];
  const changes = [];
  const seen = new Set();
  const todo = [[x, y]];
  while (todo.length) {
    const [px, py] = todo.pop();
    const key = py * picture.width + px;
    if (seen.has(key) || !inside(rect, px, py)) continue;
    seen.add(key);
    if (colourAt(picture, colours, px, py) !== was) continue;
    changes.push({ x: px, y: py, from: was, to: name });
    todo.push([px + 1, py], [px - 1, py], [px, py + 1], [px, py - 1]);
  }
  return changes;
}

// Apply a stroke one way or the other: forwards gives every pixel its `to`,
// backwards its `from` -- which is all undo and redo are. A pixel whose
// `from` was a colour with no meaning is left alone going back; there is no
// colour to put back, and it is one the build would have refused anyway.
function applyChanges(picture, colours, changes, backwards) {
  for (const c of changes) {
    const name = backwards ? c.from : c.to;
    if (name) setColour(picture, colours, c.x, c.y, name);
  }
}

// --- what the build will say ----------------------------------------------------

// The ring of pixels just outside a rectangle, where the frame goes.
function frameOf(rect) {
  const out = [];
  const left = rect.x - 1;
  const right = rect.x + rect.w;
  const top = rect.y - 1;
  const bottom = rect.y + rect.h;
  for (let x = left; x <= right; x++) {
    out.push({ x: x, y: top });
    out.push({ x: x, y: bottom });
  }
  for (let y = rect.y; y < bottom; y++) {
    out.push({ x: left, y: y });
    out.push({ x: right, y: y });
  }
  return out;
}

// What would stop the build on this sprite, as sheet.py checks it, in words.
// `strict` adds the engine's size limits, which the build applies to sprites
// from the other sheets only.
function spriteProblems(picture, colours, rect, strict) {
  const out = [];
  if (rect.x < 1 || rect.y < 1 || rect.x + rect.w + 1 > picture.width ||
      rect.y + rect.h + 1 > picture.height) {
    out.push('its frame runs off the picture');
    return out;
  }
  if (rect.w % 8) out.push('it is ' + rect.w + ' wide, which is not a whole number of bytes');
  let broken = 0;
  for (const p of frameOf(rect)) {
    if (colourAt(picture, colours, p.x, p.y) !== 'border') broken++;
  }
  if (broken) out.push(broken + ' pixel' + (broken === 1 ? '' : 's') + ' of its frame ' +
                       (broken === 1 ? 'is' : 'are') + ' not the border colour');
  let strange = 0;
  for (let y = rect.y; y < rect.y + rect.h; y++) {
    for (let x = rect.x; x < rect.x + rect.w; x++) {
      const name = colourAt(picture, colours, x, y);
      if (name === null || name === 'border') strange++;
    }
  }
  if (strange) out.push(strange + ' pixel' + (strange === 1 ? ' is' : 's are') +
                        ' a colour the sheet gives no meaning');
  if (strict && (rect.w < NARROWEST || rect.w > WIDEST || rect.h > TALLEST)) {
    out.push('it is ' + rect.w + ' × ' + rect.h + ', and the engine draws ' + NARROWEST +
             ' to ' + WIDEST + ' wide and at most ' + TALLEST + ' high');
  }
  return out;
}

// --- which graphics draw it ------------------------------------------------------

// sprite path -> the graphic numbers that draw it, out of graphics.json.
// `prefix` is how graphics.json names this sheet's sprites: '' for the game's
// own, 'doors:' for the Melkhior doors sheet, and so on.
function graphicsDrawing(graphics, prefix) {
  const out = new Map();
  const table = (graphics && graphics.graphics) || {};
  for (const name of Object.keys(table)) {
    const entry = table[name] || {};
    const sprite = entry.sprite;
    if (typeof sprite !== 'string' || !Number.isInteger(entry.number)) continue;
    if (prefix ? sprite.indexOf(prefix) !== 0 : sprite.indexOf(':') >= 0) continue;
    const path = sprite.slice(prefix.length);
    if (!out.has(path)) out.set(path, []);
    out.get(path).push(entry.number);
  }
  for (const list of out.values()) list.sort(function (a, b) { return a - b; });
  return out;
}

// --- the description, written back ---------------------------------------------

// The colours in the order the file lists them, as sheet.py's COLOUR_ORDER.
const COLOUR_ORDER = ['ink', 'paper', 'transparent', 'stray', 'border'];

// A description as text, laid out exactly as examples/filmation/scripts/
// sheet.py's format_sheet writes it -- one sprite a line, the numbers lined
// up in columns -- so that writing one back unchanged changes nothing, and a
// change diffs as the lines it touched. `eol` is the file's own line ending.
// tests/sprite_sheet_model_test.js requires every real description to come
// back out of this byte for byte.
function formatSheet(sheet, eol) {
  const said = sheet || {};
  const lines = [];
  const pad = (text, width) => text.length >= width ? text : text + ' '.repeat(width - text.length);
  const right = (text, width) => text.length >= width ? text : ' '.repeat(width - text.length) + text;

  function widths(node) {
    const out = { name: 0, x: 1, y: 1, w: 1, h: 1, trim: 1 };
    const sprites = node.sprites || {};
    for (const name of keysOf(sprites)) {
      out.name = Math.max(out.name, name.length);
      for (const k of ['x', 'y', 'w', 'h', 'trim']) {
        out[k] = Math.max(out[k], String(sprites[name][k] || 0).length);
      }
    }
    return out;
  }

  function emit(node, depth) {
    const outer = ' '.repeat(depth);
    const inner = ' '.repeat(depth + 1);
    const sprites = node.sprites || {};
    const groups = node.group || {};
    const names = keysOf(sprites);
    const groupNames = keysOf(groups);
    if (names.length) {
      const width = widths(node);
      // A sprite that lost no rows says nothing about it, which is most.
      const keys = ['x', 'y', 'w', 'h'];
      if (names.some((n) => sprites[n].trim)) keys.push('trim');
      lines.push(outer + '"sprites": {');
      names.forEach((name, i) => {
        const box = sprites[name];
        const cells = keys.map((k) => '"' + k + '": ' + right(String(box[k] || 0), width[k])).join(', ');
        lines.push(inner + pad('"' + name + '":', width.name + 3) + ' { ' + cells + ' }' +
                   (i < names.length - 1 ? ',' : ''));
      });
      lines.push(outer + '}' + (groupNames.length ? ',' : ''));
    }
    if (groupNames.length) {
      lines.push(outer + '"group": {');
      groupNames.forEach((name, i) => {
        lines.push(inner + '"' + name + '": {');
        emit(groups[name], depth + 2);
        lines.push(inner + '}' + (i < groupNames.length - 1 ? ',' : ''));
      });
      lines.push(outer + '}');
    }
  }

  const colours = coloursOf(said);
  const widest = Math.max.apply(null, COLOUR_ORDER.map((c) => c.length)) + 3;
  lines.push('{', ' "sheet": {', '  "file": "' + (((said.sheet || {}).file) || 'sprites.png') + '",',
             '  "colours": {');
  COLOUR_ORDER.forEach((name, i) => {
    lines.push('   ' + pad('"' + name + '":', widest) + ' [ ' +
               colours[name].map((v) => right(String(v), 3)).join(', ') + ' ]' +
               (i < COLOUR_ORDER.length - 1 ? ',' : ''));
  });
  lines.push('  }', ' },', ' "bytes": {',
             '  "header":      ["width", "height"],',
             '  "rows":        "bottom-up",',
             '  "interleaved": true,',
             '  "first":       "mask",',
             '  "maskBit":     "covers"',
             ' },');
  emit(said, 1);

  const animations = said.animations || {};
  const animNames = keysOf(animations);
  if (animNames.length) {
    const width = Math.max.apply(null, animNames.map((n) => n.length));
    lines[lines.length - 1] += ',';
    lines.push(' "animations": {');
    animNames.forEach((name, i) => {
      const comma = i < animNames.length - 1 ? ',' : '';
      const frames = animations[name];
      const one = '  ' + pad('"' + name + '":', width + 3) + ' [ ' +
        frames.map((n) => '"' + n + '"').join(', ') + ' ]' + comma;
      if (one.length <= 96) {
        lines.push(one);
        return;
      }
      lines.push('  "' + name + '": [');
      frames.forEach((n, j) => lines.push('   "' + n + '"' + (j < frames.length - 1 ? ',' : '')));
      lines.push('  ]' + comma);
    });
    lines.push(' }');
  }
  lines.push('}');
  return lines.join(eol || '\n') + (eol || '\n');
}

// --- sizes and places --------------------------------------------------------------
//
// A sprite's rectangle is where the build cuts it from, and the frame round it
// is how the build checks the cut. So a sprite that grows needs room for
// itself and its frame, clear of every other sprite's -- sheet.py lays them
// out with GAP between, a frame, a clear pixel and the next frame -- and one
// that has no room where it is goes where there is.

const GAP = 3;

function cloneSheet(sheet) {
  return JSON.parse(JSON.stringify(sheet));
}

function clonePicture(picture) {
  return { width: picture.width, height: picture.height, rgba: new Uint8Array(picture.rgba) };
}

// The `sprites` map that holds a sprite, and its key there.
function spriteNode(sheet, path) {
  const parts = path.split('.');
  let node = sheet;
  for (const part of parts.slice(0, -1)) {
    node = node && node.group && node.group[part];
  }
  const key = parts[parts.length - 1];
  if (!node || !node.sprites || !node.sprites[key]) return null;
  return { sprites: node.sprites, key: key };
}

// Where the picture is taken: every pixel that is not clear -- sprites,
// frames, the band names sprite_sheet.py paints -- and every sprite's
// rectangle and frame, clear pixels and all, except the one being placed.
function occupancy(picture, sprites, except) {
  const taken = new Uint8Array(picture.width * picture.height);
  for (let i = 0; i < taken.length; i++) {
    if (picture.rgba[i * 4 + 3] >= OPAQUE) taken[i] = 1;
  }
  for (const sprite of sprites) {
    if (sprite.path === except) continue;
    const r = sprite.rect;
    for (let y = Math.max(0, r.y - 1); y <= Math.min(picture.height - 1, r.y + r.h); y++) {
      for (let x = Math.max(0, r.x - 1); x <= Math.min(picture.width - 1, r.x + r.w); x++) {
        taken[y * picture.width + x] = 1;
      }
    }
  }
  return taken;
}

// Sums of the taken pixels above and left of each point, so any rectangle's
// count is four lookups -- what makes trying every place on a tall sheet
// quick.
function areaTable(taken, width, height) {
  const sums = new Uint32Array((width + 1) * (height + 1));
  for (let y = 0; y < height; y++) {
    let row = 0;
    for (let x = 0; x < width; x++) {
      row += taken[y * width + x];
      sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row;
    }
  }
  return sums;
}

function takenIn(sums, width, height, x0, y0, x1, y1) {
  const ax = Math.max(0, x0);
  const ay = Math.max(0, y0);
  const bx = Math.min(width, x1);
  const by = Math.min(height, y1);
  if (ax >= bx || ay >= by) return 0;
  const W = width + 1;
  return sums[by * W + bx] - sums[ay * W + bx] - sums[by * W + ax] + sums[ay * W + ax];
}

// Whether a rectangle can go at its place: its frame on the picture, and it,
// its frame and a clear pixel round that untaken -- so the next frame out is
// GAP from this one, as sheet.py lays them.
function fitsAt(sums, picture, rect) {
  if (rect.x < 1 || rect.y < 1 || rect.x + rect.w + 1 > picture.width ||
      rect.y + rect.h + 1 > picture.height) return false;
  return takenIn(sums, picture.width, picture.height,
                 rect.x - 2, rect.y - 2, rect.x + rect.w + 2, rect.y + rect.h + 2) === 0;
}

// The first place a w by h sprite fits, reading the picture as a page --
// top to bottom, left to right -- or null if none does.
function findSpace(picture, taken, w, h) {
  const sums = areaTable(taken, picture.width, picture.height);
  for (let y = 1; y + h + 1 <= picture.height; y++) {
    for (let x = 1; x + w + 1 <= picture.width; x++) {
      if (fitsAt(sums, picture, { x: x, y: y, w: w, h: h })) return { x: x, y: y };
    }
  }
  return null;
}

// The picture with rows of clear pixels added at the bottom.
function growPicture(picture, height) {
  if (height <= picture.height) return picture;
  const rgba = new Uint8Array(picture.width * height * 4);
  rgba.set(picture.rgba);
  return { width: picture.width, height: height, rgba: rgba };
}

function clearArea(picture, x0, y0, x1, y1) {
  for (let y = Math.max(0, y0); y < Math.min(picture.height, y1); y++) {
    picture.rgba.fill(0, (y * picture.width + Math.max(0, x0)) * 4,
                      (y * picture.width + Math.min(picture.width, x1)) * 4);
  }
}

function drawFrame(picture, colours, rect) {
  for (const p of frameOf(rect)) setColour(picture, colours, p.x, p.y, 'border');
}

// A sprite made bigger or smaller at its edges: `edges` is how many pixels
// each side moves out ({ top, bottom, left, right }, negative to take away),
// left and right in whole bytes because the build reads a sprite in bytes.
// What was there stays where it was in the sprite; new pixels are clear.
//
// It stays where it is if it still fits there, clear of every other sprite;
// otherwise it goes to the first place on the picture it fits, and the
// picture grows at the bottom if there is none. Returns { picture, sheet,
// rect, moved }, new copies with the sprite's frame drawn and its rectangle
// written, or throws with the reason.
function resizeSprite(picture, colours, sheet, path, edges) {
  const top = edges.top || 0;
  const bottom = edges.bottom || 0;
  const left = edges.left || 0;
  const right = edges.right || 0;
  if (left % 8 || right % 8) throw new Error('a sprite grows and shrinks in whole bytes across');
  const found = spriteNode(sheet, path);
  if (!found) throw new Error('there is no sprite ' + path);
  const box = found.sprites[found.key];
  const was = { x: box.x, y: box.y, w: box.w, h: box.h };
  const rect = { x: was.x - left, y: was.y - top, w: was.w + left + right, h: was.h + top + bottom };
  if (rect.w < 8) throw new Error('a sprite is at least a byte wide');
  if (rect.h < 1) throw new Error('a sprite is at least a row high');

  // Its pixels as they will be: each old one at its new place, the rest clear.
  const content = new Uint8Array(rect.w * rect.h * 4);
  for (let y = 0; y < rect.h; y++) {
    for (let x = 0; x < rect.w; x++) {
      const ox = x - left;
      const oy = y - top;
      if (ox < 0 || oy < 0 || ox >= was.w || oy >= was.h) continue;
      const from = ((was.y + oy) * picture.width + was.x + ox) * 4;
      content.set(picture.rgba.subarray(from, from + 4), (y * rect.w + x) * 4);
    }
  }

  // Off the picture, frame and all; then a place for the new size.
  let out = clonePicture(picture);
  clearArea(out, was.x - 1, was.y - 1, was.x + was.w + 1, was.y + was.h + 1);
  const sprites = allSpritesOf(sheetTree(sheet));
  let taken = occupancy(out, sprites, path);
  let place = { x: rect.x, y: rect.y };
  let moved = false;
  // A sprite growing off the bottom of the picture takes the picture with it.
  if (rect.x >= 1 && rect.y >= 1 && rect.x + rect.w + 1 <= out.width &&
      rect.y + rect.h + 1 > out.height) {
    out = growPicture(out, rect.y + rect.h + 1);
    taken = occupancy(out, sprites, path);
  }
  if (!fitsAt(areaTable(taken, out.width, out.height), out, rect)) {
    const free = findSpace(out, taken, rect.w, rect.h);
    if (free) {
      place = free;
    } else {
      place = { x: 1, y: out.height + GAP - 1 };
      out = growPicture(out, place.y + rect.h + 1);
    }
    moved = true;
  }
  const at = { x: place.x, y: place.y, w: rect.w, h: rect.h };
  for (let y = 0; y < at.h; y++) {
    out.rgba.set(content.subarray(y * at.w * 4, (y + 1) * at.w * 4),
                 ((at.y + y) * out.width + at.x) * 4);
  }
  drawFrame(out, colours, at);

  const next = cloneSheet(sheet);
  const into = spriteNode(next, path);
  Object.assign(into.sprites[into.key], { x: at.x, y: at.y, w: at.w, h: at.h });
  return { picture: out, sheet: next, rect: at, moved: moved };
}

// Every sprite laid out afresh, as sprite_sheet.py lays a new sheet: in the
// tree's order, each group from the start of a row, left to right with GAP
// between and a new row when the next would run off the edge. Only the
// sprites and their frames come across -- anything else painted on the
// picture, the band names sprite_sheet.py writes above each group among it,
// does not. The picture keeps its width and is as tall as it needs.
function tidySheet(picture, colours, sheet) {
  const tree = sheetTree(sheet);
  const places = new Map();
  let y = 1;
  (function walk(group) {
    if (group.sprites.length) {
      let x = 1;
      let tallest = 0;
      for (const sprite of group.sprites) {
        const r = sprite.rect;
        if (x > 1 && x + r.w + 1 > picture.width) {
          x = 1;
          y += tallest + GAP;
          tallest = 0;
        }
        places.set(sprite.path, { x: x, y: y, w: r.w, h: r.h });
        x += r.w + GAP;
        tallest = Math.max(tallest, r.h);
      }
      y += tallest + GAP;
    }
    for (const sub of group.groups) walk(sub);
  }(tree));

  const out = { width: picture.width, height: Math.max(1, y - GAP + 2),
                rgba: null };
  out.rgba = new Uint8Array(out.width * out.height * 4);
  const next = cloneSheet(sheet);
  for (const sprite of allSpritesOf(tree)) {
    const from = sprite.rect;
    const to = places.get(sprite.path);
    for (let row = 0; row < from.h; row++) {
      const src = ((from.y + row) * picture.width + from.x) * 4;
      out.rgba.set(picture.rgba.subarray(src, src + from.w * 4), ((to.y + row) * out.width + to.x) * 4);
    }
    drawFrame(out, colours, to);
    const into = spriteNode(next, sprite.path);
    into.sprites[into.key].x = to.x;
    into.sprites[into.key].y = to.y;
  }
  return { picture: out, sheet: next };
}

// --- what changed, for undo ------------------------------------------------------------

// The pixels that differ between two pictures of one width, as their indices
// and their colours before and after, packed four bytes to a number. A pixel
// past the shorter picture's last row counts as clear. Small for a resize,
// and the whole of a tidy -- which is still no more than the picture.
function diffPictures(a, b) {
  const height = Math.max(a.height, b.height);
  const at = [];
  const before = [];
  const after = [];
  const word = (p, i) => {
    if (i * 4 >= p.rgba.length) return 0;
    return ((p.rgba[i * 4] << 24) | (p.rgba[i * 4 + 1] << 16) | (p.rgba[i * 4 + 2] << 8) |
            p.rgba[i * 4 + 3]) >>> 0;
  };
  for (let i = 0; i < a.width * height; i++) {
    const x = word(a, i);
    const y = word(b, i);
    if (x !== y) { at.push(i); before.push(x); after.push(y); }
  }
  return { width: a.width, fromHeight: a.height, toHeight: b.height,
           at: Uint32Array.from(at), before: Uint32Array.from(before), after: Uint32Array.from(after) };
}

// One way or the other: a new picture, the height the diff says.
function applyDiff(picture, diff, backwards) {
  const height = backwards ? diff.fromHeight : diff.toHeight;
  const out = { width: diff.width, height: height, rgba: new Uint8Array(diff.width * height * 4) };
  out.rgba.set(picture.rgba.subarray(0, Math.min(picture.rgba.length, out.rgba.length)));
  const values = backwards ? diff.before : diff.after;
  for (let k = 0; k < diff.at.length; k++) {
    const i = diff.at[k];
    if (i * 4 >= out.rgba.length) continue;
    const v = values[k];
    out.rgba[i * 4] = v >>> 24;
    out.rgba[i * 4 + 1] = (v >>> 16) & 255;
    out.rgba[i * 4 + 2] = (v >>> 8) & 255;
    out.rgba[i * 4 + 3] = v & 255;
  }
  return out;
}

if (typeof module !== 'undefined') {
  module.exports = {
    DEFAULT_COLOURS, PAINTS, OPAQUE, NARROWEST, WIDEST, TALLEST, GAP,
    coloursOf, sheetTree, allSpritesOf, colourAt, setColour, inside,
    paint, fill, strokeColour, applyChanges, frameOf, spriteProblems, graphicsDrawing,
    KEYS, keysOf, parseSheet, formatSheet, spriteNode, occupancy, findSpace, resizeSprite, tidySheet,
    diffPictures, applyDiff
  };
}
