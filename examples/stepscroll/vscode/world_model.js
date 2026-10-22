// stepscroll's world, drawn the way world.py draws it: the map's pages, each a
// block of entries -- tiles from tiles.json -- with sky and rock round them
// as the tiles' bottom rows say.
//
// A port of world.py, for the designer's pages. No vscode import: the
// page inlines it, and tests/world_model_test.js checks it against world.py's
// own picture, pixel for pixel.

'use strict';

(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.StepscrollWorld = factory();
  }
}(typeof self !== 'undefined' ? self : this, function () {

  const PAGE_W = 256;
  const PAGE_H = 256;
  const PAGE_COLUMNS = PAGE_W / 8;
  const MAP_COLUMNS = 8;
  const MAX_MAP_ROWS = 32;

  const PIXELS = { '#': 1, '.': 0 };

  // tiles.json's tiles (tileset.py's parse): { groups: { name:
  // [tile names] }, tiles: { name: { name, group, bits, width, height
  // } } }, bits rows from the top of 0/1. Throws on anything wrong.
  function parseTiles(doc) {
    if (!doc || typeof doc.groups !== 'object' || doc.groups === null) {
      throw new Error('tiles.json: no "groups"');
    }
    const groups = {};
    const tiles = {};
    for (const gname of Object.keys(doc.groups)) {
      const names = [];
      for (const name of Object.keys(doc.groups[gname].tiles || {})) {
        if (tiles[name]) {
          throw new Error(`tiles.json: tile ${name} is in groups ${tiles[name].group} and ${gname}`);
        }
        const rows = doc.groups[gname].tiles[name].rows;
        if (!Array.isArray(rows) || !rows.length || rows.length % 2 || typeof rows[0] !== 'string' ||
            !rows[0].length || rows[0].length % 8 ||
            rows.some(r => typeof r !== 'string' || r.length !== rows[0].length || /[^#.]/.test(r))) {
          throw new Error(`tiles.json: tile ${name}: rows must be an even number of rows of a whole ` +
                          `number of bytes of '#' or '.'`);
        }
        const strip = doc.groups[gname].tiles[name].shiftIn || rows.map(() => '......');
        if (!Array.isArray(strip) || strip.length !== rows.length ||
            strip.some(r => typeof r !== 'string' || r.length !== 6 || /[^#.]/.test(r))) {
          throw new Error(`tiles.json: tile ${name}: shiftIn must be a row of 6 '#' or '.' for each of its ` +
                          `${rows.length} rows`);
        }
        tiles[name] = {
          name, group: gname, bits: rows.map(r => Array.from(r, ch => PIXELS[ch])),
          shiftIn: strip.map(r => Array.from(r, ch => PIXELS[ch])),
          width: rows[0].length / 8, height: rows.length,
        };
        names.push(name);
      }
      groups[gname] = names;
    }
    return { groups, tiles };
  }

  // A block's entries with their tiles (world.py's World.entries), checked
  // to be in the page with an odd bottom line.
  function blockEntries(blocks, name, tiles) {
    if (!blocks[name]) {
      throw new Error('no block named ' + JSON.stringify(name));
    }
    return (blocks[name].entries || []).map((e, k) => {
      const g = tiles.tiles[e.tile];
      if (!g) {
        throw new Error(`block ${name}, entry ${k}: no tile ${JSON.stringify(e.tile)} in tiles.json`);
      }
      if (e.bottom % 2 === 0) {
        throw new Error(`block ${name}, entry ${k}: bottom line ${e.bottom} is even; the blitters go up a row ` +
                        `pair at a time from an odd line`);
      }
      if (!(e.column >= 0 && e.column + g.width <= PAGE_COLUMNS && e.bottom - g.height + 1 >= 0 &&
            e.bottom < PAGE_H)) {
        throw new Error(`block ${name}, entry ${k}: ${g.name} at column ${e.column}, line ${e.bottom} leaves the page`);
      }
      return { tile: g.name, column: e.column, bottom: e.bottom, width: g.width, rows: g.height, bits: g.bits,
               index: k };
    });
  }

  // What is wrong with a block, as messages: world.py's checks.
  function blockProblems(blocks, name, tiles) {
    try {
      blockEntries(blocks, name, tiles);
      return [];
    } catch (err) {
      return [err.message];
    }
  }

  // The world as pixels -- world.py's World.bytes unpacked: { width, height,
  // bits } with bits a Uint8Array of 0/1 row by row: every block's entries in
  // order, and below each tile, down its columns, rock (the checker) or
  // sky as its bottom row shows there; sky from the top of the world. Also
  // `entries` (each placed: block, mapRow, mapColumn and the entry) and
  // `owner` (the entry that drew each pixel, an index into `entries`, or -1),
  // for picking.
  function render(blocks, rows, tiles) {
    const width = PAGE_W * MAP_COLUMNS;
    const height = PAGE_H * rows.length;
    const bits = new Uint8Array(width * height);
    const owner = new Int32Array(width * height).fill(-1);
    const entries = [];
    rows.forEach((row, r) => {
      row.forEach((name, c) => {
        for (const e of blockEntries(blocks, name, tiles)) {
          const index = entries.length;
          entries.push(Object.assign({ block: name, mapRow: r, mapColumn: c }, e));
          const top = r * PAGE_H + e.bottom - e.rows + 1;
          const left = (c * PAGE_COLUMNS + e.column) * 8;
          for (let i = 0; i < e.rows; i++) {
            for (let b = 0; b < 8 * e.width; b++) {
              const at = (top + i) * width + left + b;
              bits[at] = e.bits[i][b];
              owner[at] = index;
            }
          }
        }
      });
    });
    // The sky and rock round the tiles, column by column.
    for (let x = 0; x < width; x++) {
      let rock = false;
      for (let y = 0; y < height; y++) {
        const at = y * width + x;
        const even = (x + y) % 2 === 0;
        if (owner[at] >= 0) {
          // Rock if the pixel of this one's pair on an even x + y is set.
          rock = (even ? bits[at] : bits[y * width + (x ^ 1)]) === 1;
        } else {
          bits[at] = rock && even ? 1 : 0;
        }
      }
    }
    return { width, height, bits, owner, entries };
  }

  // Where scrolling goes wrong (build.py's coverage check): every byte of the
  // world that some move -- 2 pixels left or right, 2 lines up or down, to
  // any fine position -- changes, and that no entry draws, so that it keeps
  // what it showed before. `world` is render's. Returns a Uint8Array of
  // world.height x (world.width / 8), 1 for each such byte. (A left-column
  // fill is not counted as drawing it: stepscroll.s has them off.)
  function coverageGaps(world) {
    const W8 = world.width / 8;
    const H = world.height;
    // The world shifted right by 0, 2, 4 or 6 pixels, as bytes.
    const cuts = {};
    for (const f of [0, 2, 4, 6]) {
      const c = new Uint8Array(H * W8);
      for (let y = 0; y < H; y++) {
        const row = y * world.width;
        for (let k = 0; k < W8; k++) {
          let v = 0;
          for (let b = 0; b < 8; b++) {
            v = (v << 1) | world.bits[row + (((8 * k + b - f) % world.width) + world.width) % world.width];
          }
          c[y * W8 + k] = v;
        }
      }
      cuts[f] = c;
    }
    // The bytes some entry draws.
    const foot = new Uint8Array(H * W8);
    for (const e of world.entries) {
      const top = e.mapRow * PAGE_H + e.bottom - e.rows + 1;
      for (let i = 0; i < e.rows; i++) {
        for (let j = 0; j < e.width; j++) {
          foot[(top + i) * W8 + (e.mapColumn * PAGE_COLUMNS + e.column + j) % W8] = 1;
        }
      }
    }
    const gaps = new Uint8Array(H * W8);
    for (const [mx, my] of [[2, 0], [-2, 0], [0, 2], [0, -2]]) {
      for (const fine of [0, 2, 4, 6]) {
        const now = cuts[fine];
        const before = cuts[(((fine - mx) % 8) + 8) % 8];
        // Moving right back to fine 0 a byte's picture comes from the byte
        // to its right; moving left to fine 6, from the one to its left.
        const dk = mx === 2 && fine === 0 ? 1 : mx === -2 && fine === 6 ? -1 : 0;
        for (let y = 0; y < H; y++) {
          const yb = y + my;
          if (yb < 0 || yb >= H) continue;
          for (let k = 0; k < W8; k++) {
            const at = y * W8 + k;
            if (foot[at] || gaps[at]) continue;
            if (now[at] !== before[yb * W8 + (k + dk + W8) % W8]) gaps[at] = 1;
          }
        }
      }
    }
    return gaps;
  }

  return { PAGE_W, PAGE_H, PAGE_COLUMNS, MAP_COLUMNS, MAX_MAP_ROWS, PIXELS,
           parseTiles, blockEntries, blockProblems, render, coverageGaps };
}));
