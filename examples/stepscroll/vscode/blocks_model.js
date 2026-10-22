// stepscroll's blocks, world/blocks.json, as the block editor edits them: a block
// is its entries -- tiles from tiles.json at a byte column and a bottom
// line -- and the edits are entries placed, moved, reordered and removed,
// and blocks added, copied, renamed and removed. A block's rename or removal
// reaches map.json, whose rows name blocks, so those take both documents.
//
// No vscode import: the page inlines it (after world_model.js and
// tiles_model.js, whose formatBlocks writes the file), and
// tests/blocks_model_test.js runs it from plain Node.

'use strict';

(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory(require('./world_model'), require('./tiles_model'));
  } else {
    root.StepscrollBlocks = factory(root.StepscrollWorld, root.StepscrollTiles);
  }
}(typeof self !== 'undefined' ? self : this, function (W, S) {

  function clone(doc) {
    return JSON.parse(JSON.stringify(doc));
  }

  // map.json as it is laid out: a row of the map to a line.
  function formatMap(doc, eol) {
    const lines = ['{'];
    if (doc.$schema !== undefined) {
      lines.push('  "$schema": ' + JSON.stringify(doc.$schema) + ',');
    }
    lines.push('  "rows": [');
    doc.rows.forEach((row, i) => {
      lines.push('    [' + row.map(n => JSON.stringify(n)).join(', ') + ']' + (i < doc.rows.length - 1 ? ',' : ''));
    });
    lines.push('  ]', '}', '');
    return lines.join('\n').replace(/\n/g, eol || '\n');
  }

  // Where a block is on the map: [[row, column], ...].
  function places(mapDoc, name) {
    const out = [];
    mapDoc.rows.forEach((row, r) => row.forEach((n, c) => {
      if (n === name) out.push([r, c]);
    }));
    return out;
  }

  // What would make `name` a bad new block name, or null.
  function badName(blocksDoc, name) {
    if (typeof name !== 'string' || !name.trim() || name !== name.trim()) {
      return 'a name needs some letters, and no spaces at either end';
    }
    if (blocksDoc.blocks[name]) {
      return `there is already a block named ${name}`;
    }
    return null;
  }

  // An object with one key renamed, keeping its place.
  function renameKey(obj, from, to) {
    const out = {};
    for (const k of Object.keys(obj)) {
      out[k === from ? to : k] = obj[k];
    }
    return out;
  }

  // ---- blocks ----------------------------------------------------------------

  // A new block, empty -- or a copy of `from`.
  function addBlock(blocksDoc, name, from) {
    const bad = badName(blocksDoc, name);
    if (bad) throw new Error(bad);
    const out = clone(blocksDoc);
    out.blocks[name] = from ? clone(blocksDoc.blocks[from]) : { entries: [] };
    return out;
  }

  function renameBlock(blocksDoc, mapDoc, from, to) {
    if (from === to) return { blocks: blocksDoc, map: mapDoc };
    const bad = badName(blocksDoc, to);
    if (bad) throw new Error(bad);
    const blocks = clone(blocksDoc);
    blocks.blocks = renameKey(blocks.blocks, from, to);
    const map = clone(mapDoc);
    map.rows = map.rows.map(row => row.map(n => (n === from ? to : n)));
    return { blocks, map };
  }

  function removeBlock(blocksDoc, mapDoc, name) {
    const at = places(mapDoc, name);
    if (at.length) {
      throw new Error(`${name} is on the map ${at.length} time${at.length > 1 ? 's' : ''} ` +
                      `(first at row ${at[0][0]}, column ${at[0][1]})`);
    }
    if (Object.keys(blocksDoc.blocks).length === 1) {
      throw new Error('the last block stays');
    }
    const out = clone(blocksDoc);
    delete out.blocks[name];
    return out;
  }

  // ---- entries --------------------------------------------------------------

  // An entry's place made legal: a byte column, an odd bottom line, the
  // tile inside the page.
  function snap(tile, column, bottom) {
    const c = Math.max(0, Math.min(W.PAGE_COLUMNS - tile.width, Math.round(column)));
    let b = Math.round(bottom);
    b = Math.max(tile.height - 1, Math.min(W.PAGE_H - 1, b));
    if (b % 2 === 0) b = b + 1 <= W.PAGE_H - 1 ? b + 1 : b - 1;
    return { column: c, bottom: b };
  }

  // A tile added to a block at (column, bottom), drawn last.
  function addEntry(blocksDoc, block, tiles, tile, column, bottom) {
    const g = tiles.tiles[tile];
    if (!g) throw new Error(`no tile ${tile}`);
    const out = clone(blocksDoc);
    out.blocks[block].entries = out.blocks[block].entries || [];
    out.blocks[block].entries.push(Object.assign({ tile }, snap(g, column, bottom)));
    return out;
  }

  function moveEntry(blocksDoc, block, tiles, k, column, bottom) {
    const out = clone(blocksDoc);
    const e = out.blocks[block].entries[k];
    Object.assign(e, snap(tiles.tiles[e.tile], column, bottom));
    return out;
  }

  function removeEntry(blocksDoc, block, k) {
    const out = clone(blocksDoc);
    out.blocks[block].entries.splice(k, 1);
    return out;
  }

  // An entry moved `by` places in the drawing order (later draws over earlier).
  function reorderEntry(blocksDoc, block, k, by) {
    const out = clone(blocksDoc);
    const list = out.blocks[block].entries;
    const j = Math.max(0, Math.min(list.length - 1, k + by));
    const [e] = list.splice(k, 1);
    list.splice(j, 0, e);
    return { blocks: out, index: j };
  }

  // The entry drawn on top at page pixel (x, y): the last one there, or -1.
  function entryAt(blocksDoc, block, tiles, x, y) {
    const list = blocksDoc.blocks[block].entries || [];
    for (let k = list.length - 1; k >= 0; k--) {
      const e = list[k];
      const g = tiles.tiles[e.tile];
      if (!g) continue;
      if (x >= e.column * 8 && x < (e.column + g.width) * 8 && y > e.bottom - g.height && y <= e.bottom) {
        return k;
      }
    }
    return -1;
  }

  return { formatMap, formatBlocks: S.formatBlocks, places, badName, addBlock, renameBlock, removeBlock, snap,
           addEntry, moveEntry, removeEntry, reorderEntry, entryAt };
}));
