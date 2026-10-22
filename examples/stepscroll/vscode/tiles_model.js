// stepscroll's tiles, world/tiles.json, as the tiles editor edits them:
// reading and writing the file in its own layout (tileset.py's
// format_doc), and the edits -- a tile's pixels or size, a tile or a
// group added, renamed, rearranged or removed. A tile's rename reaches
// blocks.json too, whose entries name tiles, so that edit takes both
// documents and gives back both.
//
// No vscode import: the page inlines it (after world_model.js), and
// tests/tiles_model_test.js runs it from plain Node.

'use strict';

(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory(require('./world_model'));
  } else {
    root.StepscrollTiles = factory(root.StepscrollWorld);
  }
}(typeof self !== 'undefined' ? self : this, function (W) {

  // The biggest tile an entry can draw: the widest blitter, and the rows
  // the blitters go to (build.py's MAX_ROWS).
  const MAX_BYTES = 3;
  const MAX_ROWS = 24;
  // The pixels the furthest shift (6) brings in on the left (tileset.py's STRIP).
  const STRIP = 6;

  function parse(text) {
    const doc = JSON.parse(text);
    W.parseTiles(doc);   // throws on anything wrong
    return doc;
  }

  // A value written as Python's json.dumps(v, separators=(", ", ": ")) does.
  function flat(v) {
    if (Array.isArray(v)) {
      return '[' + v.map(flat).join(', ') + ']';
    }
    if (v !== null && typeof v === 'object') {
      return '{' + Object.keys(v).map(k => JSON.stringify(k) + ': ' + flat(v[k])).join(', ') + '}';
    }
    return JSON.stringify(v);
  }

  // tiles.json as tileset.py's format_doc lays it out: a bitmap's rows
  // one to a line, so that a pixel edited is a line changed.
  function format(doc, eol) {
    const lines = ['{'];
    if (doc.$schema !== undefined) {
      lines.push('  "$schema": ' + JSON.stringify(doc.$schema) + ',');
    }
    lines.push('  "groups": {');
    const gnames = Object.keys(doc.groups);
    gnames.forEach((gname, i) => {
      const group = doc.groups[gname];
      lines.push('    ' + JSON.stringify(gname) + ': {');
      if (group.direction !== undefined) {
        lines.push('      "direction": ' + JSON.stringify(group.direction) + ',');
      }
      lines.push('      "tiles": {');
      const names = Object.keys(group.tiles);
      names.forEach((name, j) => {
        const g = group.tiles[name];
        lines.push('        ' + JSON.stringify(name) + ': {');
        if (g.shiftIn !== undefined) {
          lines.push('          "shiftIn": [');
          lines.push(g.shiftIn.map(r => '            ' + JSON.stringify(r)).join(',\n'));
          lines.push('          ],');
        }
        lines.push('          "rows": [');
        lines.push(g.rows.map(r => '            ' + JSON.stringify(r)).join(',\n'));
        lines.push('          ]');
        lines.push('        }' + (j < names.length - 1 ? ',' : ''));
      });
      lines.push('      }');
      lines.push('    }' + (i < gnames.length - 1 ? ',' : ''));
    });
    lines.push('  }', '}', '');
    return lines.join('\n').replace(/\n/g, eol || '\n');
  }

  // blocks.json as tileset.py's format_blocks lays it out: a block's plain
  // fields on one line, then each list (entries) an item to a line.
  function formatBlocks(doc, eol) {
    const lines = ['{'];
    if (doc.$schema !== undefined) {
      lines.push('  "$schema": ' + JSON.stringify(doc.$schema) + ',');
    }
    lines.push('  "blocks": {');
    const names = Object.keys(doc.blocks);
    names.forEach((name, i) => {
      const block = doc.blocks[name];
      const keys = Object.keys(block);
      const plain = keys.filter(k => !Array.isArray(block[k]));
      const lists = keys.filter(k => Array.isArray(block[k]));
      lines.push('    ' + JSON.stringify(name) + ': {');
      const parts = [];
      if (plain.length) {
        parts.push(['      ' + plain.map(k => JSON.stringify(k) + ': ' + JSON.stringify(block[k])).join(', ')]);
      }
      for (const k of lists) {
        const items = block[k];
        if (!items.length) {
          parts.push(['      ' + JSON.stringify(k) + ': []']);
          continue;
        }
        const part = ['      ' + JSON.stringify(k) + ': ['];
        items.forEach((v, j) => part.push('        ' + flat(v) + (j < items.length - 1 ? ',' : '')));
        part.push('      ]');
        parts.push(part);
      }
      parts.forEach((part, j) => {
        if (j < parts.length - 1) {
          part[part.length - 1] += ',';
        }
        lines.push(...part);
      });
      lines.push('    }' + (i < names.length - 1 ? ',' : ''));
    });
    lines.push('  }', '}', '');
    return lines.join('\n').replace(/\n/g, eol || '\n');
  }

  function clone(doc) {
    return JSON.parse(JSON.stringify(doc));
  }

  // Where a tile is: { group, g } in the document, or null.
  function find(doc, name) {
    for (const gname of Object.keys(doc.groups)) {
      const g = doc.groups[gname].tiles[name];
      if (g) {
        return { group: gname, g };
      }
    }
    return null;
  }

  // What would make `name` a bad new name for a tile or a group, or null.
  function badName(doc, name, kind) {
    if (typeof name !== 'string' || !name.trim() || name !== name.trim()) {
      return 'a name needs some letters, and no spaces at either end';
    }
    if (kind === 'group' ? doc.groups[name] : find(doc, name)) {
      return `there is already a ${kind} named ${name}`;
    }
    return null;
  }

  // The blocks' entries drawing a tile, as strings to show.
  function uses(blocksDoc, name) {
    const out = [];
    for (const [tname, block] of Object.entries(blocksDoc.blocks)) {
      (block.entries || []).forEach((e, k) => {
        if (e.tile === name) {
          out.push(`block ${tname}, entry ${k}`);
        }
      });
    }
    return out;
  }

  // ---- edits: each returns the new document(s), or throws an Error to show --

  // A tile's rows replaced (strings of '#' and '.'), and its shift-in
  // strip with them if given.
  function setRows(doc, name, rows, shiftIn) {
    const out = clone(doc);
    const g = find(out, name).g;
    g.rows = rows.slice();
    if (shiftIn) {
      g.shiftIn = shiftIn.slice();
    }
    return out;
  }

  // A tile's shift-in strip, clear if it has none.
  function shiftInOf(g) {
    return g.shiftIn || g.rows.map(() => '.'.repeat(STRIP));
  }

  // The tile at fine position `fine` (0, 2, 4, 6): shifted right, its last
  // pixels gone and the last `fine` of its strip in on the left (build.py's
  // tile). Rows of '#' and '.'.
  function shifted(g, fine) {
    const strip = shiftInOf(g);
    return g.rows.map((r, i) => (strip[i].slice(STRIP - fine) + r).slice(0, r.length));
  }

  // A new tile in a group: 1 byte by 8 rows, clear -- or a copy of `from`.
  function addTile(doc, group, name, from) {
    const bad = badName(doc, name, 'tile');
    if (bad) {
      throw new Error(bad);
    }
    const out = clone(doc);
    out.groups[group].tiles[name] = from ? clone(find(doc, from).g)
      : { shiftIn: Array(8).fill('.'.repeat(STRIP)), rows: Array(8).fill('.'.repeat(8)) };
    return out;
  }

  function removeTile(doc, blocksDoc, name) {
    const used = uses(blocksDoc, name);
    if (used.length) {
      const more = used.length > 3 ? `, and ${used.length - 3} more` : '';
      throw new Error(`${name} is in use: ${used.slice(0, 3).join('; ')}${more}`);
    }
    const out = clone(doc);
    delete out.groups[find(out, name).group].tiles[name];
    return out;
  }

  // An object with one key renamed, keeping its place.
  function renameKey(obj, from, to) {
    const out = {};
    for (const k of Object.keys(obj)) {
      out[k === from ? to : k] = obj[k];
    }
    return out;
  }

  function renameTile(doc, blocksDoc, from, to) {
    if (from === to) {
      return { tiles: doc, blocks: blocksDoc };
    }
    const bad = badName(doc, to, 'tile');
    if (bad) {
      throw new Error(bad);
    }
    const tiles = clone(doc);
    const group = find(tiles, from).group;
    tiles.groups[group].tiles = renameKey(tiles.groups[group].tiles, from, to);
    const blocks = clone(blocksDoc);
    for (const block of Object.values(blocks.blocks)) {
      for (const e of block.entries || []) {
        if (e.tile === from) {
          e.tile = to;
        }
      }
    }
    return { tiles, blocks };
  }

  // A tile put in `toGroup` just before `before` (a tile's name), or
  // last with null: rearranging by dragging. Groups only organise: the
  // blocks name tiles, not groups.
  function place(doc, name, toGroup, before) {
    if (name === before) {
      return doc;
    }
    const out = clone(doc);
    const at = find(out, name);
    delete out.groups[at.group].tiles[name];
    const group = out.groups[toGroup];
    const names = Object.keys(group.tiles);
    const i = before === null ? names.length : names.indexOf(before);
    names.splice(i < 0 ? names.length : i, 0, name);
    const tiles = {};
    for (const n of names) {
      tiles[n] = n === name ? at.g : group.tiles[n];
    }
    group.tiles = tiles;
    return out;
  }

  // The bitmap made `bytes` bytes wide and `rows` rows high: cut off, or
  // grown with clear pixels, at the right and the bottom.
  // The tile's pixels moved `dx` pixels right and `dy` rows down, round
  // and round: what goes off one side comes back on the other, so nothing is
  // lost and the opposite move undoes it. Moving up or down takes the
  // shift-in strip with its rows.
  function shiftTile(doc, name, dx, dy) {
    const out = clone(doc);
    const g = find(out, name).g;
    const turn = (list, by) => {
      const n = list.length;
      const k = ((by % n) + n) % n;
      return k ? list.slice(n - k).concat(list.slice(0, n - k)) : list.slice();
    };
    let rows = g.rows.map(r => turn(Array.from(r), dx).join(''));
    rows = turn(rows, dy);
    g.rows = rows;
    if (dy) {
      g.shiftIn = turn(shiftInOf(g), dy);
    }
    return out;
  }

  function setSize(doc, name, bytes, rows) {
    if (!Number.isInteger(bytes) || bytes < 1 || bytes > MAX_BYTES ||
        !Number.isInteger(rows) || rows < 2 || rows > MAX_ROWS || rows % 2) {
      throw new Error(`a tile is 1 to ${MAX_BYTES} bytes wide and an even number of rows, 2 to ${MAX_ROWS}`);
    }
    const out = clone(doc);
    const g = find(out, name).g;
    const w = 8 * bytes;
    const resized = g.rows.slice(0, rows).map(r => (r + '.'.repeat(w)).slice(0, w));
    while (resized.length < rows) {
      resized.push('.'.repeat(w));
    }
    const strip = shiftInOf(g).slice(0, rows);
    while (strip.length < rows) {
      strip.push('.'.repeat(STRIP));
    }
    g.shiftIn = strip;
    g.rows = resized;
    return out;
  }

  function addGroup(doc, name) {
    const bad = badName(doc, name, 'group');
    if (bad) {
      throw new Error(bad);
    }
    const out = clone(doc);
    out.groups[name] = { tiles: {} };
    return out;
  }

  function renameGroup(doc, from, to) {
    if (from === to) {
      return doc;
    }
    const bad = badName(doc, to, 'group');
    if (bad) {
      throw new Error(bad);
    }
    const out = clone(doc);
    out.groups = renameKey(out.groups, from, to);
    return out;
  }

  function removeGroup(doc, name) {
    if (Object.keys(doc.groups[name].tiles).length) {
      throw new Error(`${name} still has tiles`);
    }
    const out = clone(doc);
    delete out.groups[name];
    return out;
  }

  return { MAX_BYTES, MAX_ROWS, STRIP, shiftInOf, shifted, shiftTile, parse, format, formatBlocks, clone, find, badName, uses, setRows, addTile,
           removeTile, renameTile, place, setSize, addGroup, renameGroup, removeGroup };
}));
