// stepscroll's world, drawn the way world.py draws it: the map's pages, each a
// tile of entries -- graphics from steps.json -- with sky and rock round them
// as the graphics' bottom rows say.
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

  // steps.json's graphics (step_graphics.py's parse): { groups: { name:
  // [graphic names] }, graphics: { name: { name, group, bits, width, height
  // } } }, bits rows from the top of 0/1. Throws on anything wrong.
  function parseGraphics(doc) {
    if (!doc || typeof doc.groups !== 'object' || doc.groups === null) {
      throw new Error('steps.json: no "groups"');
    }
    const groups = {};
    const graphics = {};
    for (const gname of Object.keys(doc.groups)) {
      const names = [];
      for (const name of Object.keys(doc.groups[gname].graphics || {})) {
        if (graphics[name]) {
          throw new Error(`steps.json: graphic ${name} is in groups ${graphics[name].group} and ${gname}`);
        }
        const rows = doc.groups[gname].graphics[name].rows;
        if (!Array.isArray(rows) || !rows.length || rows.length % 2 || typeof rows[0] !== 'string' ||
            !rows[0].length || rows[0].length % 8 ||
            rows.some(r => typeof r !== 'string' || r.length !== rows[0].length || /[^#.]/.test(r))) {
          throw new Error(`steps.json: graphic ${name}: rows must be an even number of rows of a whole ` +
                          `number of bytes of '#' or '.'`);
        }
        const strip = doc.groups[gname].graphics[name].shiftIn || rows.map(() => '......');
        if (!Array.isArray(strip) || strip.length !== rows.length ||
            strip.some(r => typeof r !== 'string' || r.length !== 6 || /[^#.]/.test(r))) {
          throw new Error(`steps.json: graphic ${name}: shiftIn must be a row of 6 '#' or '.' for each of its ` +
                          `${rows.length} rows`);
        }
        graphics[name] = {
          name, group: gname, bits: rows.map(r => Array.from(r, ch => PIXELS[ch])),
          shiftIn: strip.map(r => Array.from(r, ch => PIXELS[ch])),
          width: rows[0].length / 8, height: rows.length,
        };
        names.push(name);
      }
      groups[gname] = names;
    }
    return { groups, graphics };
  }

  // A tile's entries with their graphics (world.py's World.entries), checked
  // to be in the page with an odd bottom line.
  function tileEntries(tiles, name, graphics) {
    if (!tiles[name]) {
      throw new Error('no tile named ' + JSON.stringify(name));
    }
    return (tiles[name].entries || []).map((e, k) => {
      const g = graphics.graphics[e.graphic];
      if (!g) {
        throw new Error(`tile ${name}, entry ${k}: no graphic ${JSON.stringify(e.graphic)} in steps.json`);
      }
      if (e.bottom % 2 === 0) {
        throw new Error(`tile ${name}, entry ${k}: bottom line ${e.bottom} is even; the blitters go up a row ` +
                        `pair at a time from an odd line`);
      }
      if (!(e.column >= 0 && e.column + g.width <= PAGE_COLUMNS && e.bottom - g.height + 1 >= 0 &&
            e.bottom < PAGE_H)) {
        throw new Error(`tile ${name}, entry ${k}: ${g.name} at column ${e.column}, line ${e.bottom} leaves the page`);
      }
      return { graphic: g.name, column: e.column, bottom: e.bottom, width: g.width, rows: g.height, bits: g.bits,
               index: k };
    });
  }

  // What is wrong with a tile, as messages: world.py's checks.
  function tileProblems(tiles, name, graphics) {
    try {
      tileEntries(tiles, name, graphics);
      return [];
    } catch (err) {
      return [err.message];
    }
  }

  // The world as pixels -- world.py's World.bytes unpacked: { width, height,
  // bits } with bits a Uint8Array of 0/1 row by row: every tile's entries in
  // order, and below each graphic, down its columns, rock (the checker) or
  // sky as its bottom row shows there; sky from the top of the world. Also
  // `entries` (each placed: tile, mapRow, mapColumn and the entry) and
  // `owner` (the entry that drew each pixel, an index into `entries`, or -1),
  // for picking.
  function render(tiles, rows, graphics) {
    const width = PAGE_W * MAP_COLUMNS;
    const height = PAGE_H * rows.length;
    const bits = new Uint8Array(width * height);
    const owner = new Int32Array(width * height).fill(-1);
    const entries = [];
    rows.forEach((row, r) => {
      row.forEach((name, c) => {
        for (const e of tileEntries(tiles, name, graphics)) {
          const index = entries.length;
          entries.push(Object.assign({ tile: name, mapRow: r, mapColumn: c }, e));
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
    // The sky and rock round the graphics, column by column.
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

  return { PAGE_W, PAGE_H, PAGE_COLUMNS, MAP_COLUMNS, MAX_MAP_ROWS, PIXELS,
           parseGraphics, tileEntries, tileProblems, render };
}));
