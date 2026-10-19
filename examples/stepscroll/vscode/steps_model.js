// stepscroll's graphics, world/steps.json, as the graphics editor edits them:
// reading and writing the file in its own layout (step_graphics.py's
// format_doc), and the edits -- a graphic's pixels or size, a graphic or a
// group added, renamed, rearranged or removed. A graphic's rename reaches
// tiles.json too, whose entries name graphics, so that edit takes both
// documents and gives back both.
//
// No vscode import: the page inlines it (after world_model.js), and
// tests/steps_model_test.js runs it from plain Node.

'use strict';

(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory(require('./world_model'));
  } else {
    root.StepscrollSteps = factory(root.StepscrollWorld);
  }
}(typeof self !== 'undefined' ? self : this, function (W) {

  // The biggest graphic an entry can draw: the widest blitter, and the rows
  // above the hidden bottom two character rows (build.py's MAX_ROWS).
  const MAX_BYTES = 3;
  const MAX_ROWS = 16;
  // The pixels the furthest shift (6) brings in on the left (step_graphics.py's STRIP).
  const STRIP = 6;

  function parse(text) {
    const doc = JSON.parse(text);
    W.parseGraphics(doc);   // throws on anything wrong
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

  // steps.json as step_graphics.py's format_doc lays it out: a bitmap's rows
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
      lines.push('      "graphics": {');
      const names = Object.keys(group.graphics);
      names.forEach((name, j) => {
        const g = group.graphics[name];
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

  // tiles.json as step_graphics.py's format_tiles lays it out: a tile's plain
  // fields on one line, then each list (pieces, entries) an item to a line.
  function formatTiles(doc, eol) {
    const lines = ['{'];
    if (doc.$schema !== undefined) {
      lines.push('  "$schema": ' + JSON.stringify(doc.$schema) + ',');
    }
    lines.push('  "tiles": {');
    const names = Object.keys(doc.tiles);
    names.forEach((name, i) => {
      const tile = doc.tiles[name];
      const keys = Object.keys(tile);
      const plain = keys.filter(k => !Array.isArray(tile[k]));
      const lists = keys.filter(k => Array.isArray(tile[k]));
      lines.push('    ' + JSON.stringify(name) + ': {');
      const parts = [];
      if (plain.length) {
        parts.push(['      ' + plain.map(k => JSON.stringify(k) + ': ' + JSON.stringify(tile[k])).join(', ')]);
      }
      for (const k of lists) {
        const items = tile[k];
        if (!items.length) {
          parts.push(['      ' + JSON.stringify(k) + ': []']);
          continue;
        }
        const block = ['      ' + JSON.stringify(k) + ': ['];
        items.forEach((v, j) => block.push('        ' + flat(v) + (j < items.length - 1 ? ',' : '')));
        block.push('      ]');
        parts.push(block);
      }
      parts.forEach((block, j) => {
        if (j < parts.length - 1) {
          block[block.length - 1] += ',';
        }
        lines.push(...block);
      });
      lines.push('    }' + (i < names.length - 1 ? ',' : ''));
    });
    lines.push('  }', '}', '');
    return lines.join('\n').replace(/\n/g, eol || '\n');
  }

  function clone(doc) {
    return JSON.parse(JSON.stringify(doc));
  }

  // Where a graphic is: { group, g } in the document, or null.
  function find(doc, name) {
    for (const gname of Object.keys(doc.groups)) {
      const g = doc.groups[gname].graphics[name];
      if (g) {
        return { group: gname, g };
      }
    }
    return null;
  }

  // What would make `name` a bad new name for a graphic or a group, or null.
  function badName(doc, name, kind) {
    if (typeof name !== 'string' || !name.trim() || name !== name.trim()) {
      return 'a name needs some letters, and no spaces at either end';
    }
    if (kind === 'group' ? doc.groups[name] : find(doc, name)) {
      return `there is already a ${kind} named ${name}`;
    }
    return null;
  }

  // The tiles' entries drawing a graphic, as strings to show.
  function uses(tilesDoc, name) {
    const out = [];
    for (const [tname, tile] of Object.entries(tilesDoc.tiles)) {
      (tile.entries || []).forEach((e, k) => {
        if (e.graphic === name) {
          out.push(`tile ${tname}, entry ${k}`);
        }
      });
    }
    return out;
  }

  // ---- edits: each returns the new document(s), or throws an Error to show --

  // A graphic's rows replaced (strings of '#' and '.'), and its shift-in
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

  // A graphic's shift-in strip, clear if it has none.
  function shiftInOf(g) {
    return g.shiftIn || g.rows.map(() => '.'.repeat(STRIP));
  }

  // The graphic at fine position `fine` (0, 2, 4, 6): shifted right, its last
  // pixels gone and the last `fine` of its strip in on the left (build.py's
  // graphic). Rows of '#' and '.'.
  function shifted(g, fine) {
    const strip = shiftInOf(g);
    return g.rows.map((r, i) => (strip[i].slice(STRIP - fine) + r).slice(0, r.length));
  }

  // A new graphic in a group: 1 byte by 8 rows, clear -- or a copy of `from`.
  function addGraphic(doc, group, name, from) {
    const bad = badName(doc, name, 'graphic');
    if (bad) {
      throw new Error(bad);
    }
    const out = clone(doc);
    out.groups[group].graphics[name] = from ? clone(find(doc, from).g)
      : { shiftIn: Array(8).fill('.'.repeat(STRIP)), rows: Array(8).fill('.'.repeat(8)) };
    return out;
  }

  function removeGraphic(doc, tilesDoc, name) {
    const used = uses(tilesDoc, name);
    if (used.length) {
      const more = used.length > 3 ? `, and ${used.length - 3} more` : '';
      throw new Error(`${name} is in use: ${used.slice(0, 3).join('; ')}${more}`);
    }
    const out = clone(doc);
    delete out.groups[find(out, name).group].graphics[name];
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

  function renameGraphic(doc, tilesDoc, from, to) {
    if (from === to) {
      return { steps: doc, tiles: tilesDoc };
    }
    const bad = badName(doc, to, 'graphic');
    if (bad) {
      throw new Error(bad);
    }
    const steps = clone(doc);
    const group = find(steps, from).group;
    steps.groups[group].graphics = renameKey(steps.groups[group].graphics, from, to);
    const tiles = clone(tilesDoc);
    for (const tile of Object.values(tiles.tiles)) {
      for (const e of tile.entries || []) {
        if (e.graphic === from) {
          e.graphic = to;
        }
      }
    }
    return { steps, tiles };
  }

  // A graphic put in `toGroup` just before `before` (a graphic's name), or
  // last with null: rearranging by dragging. Groups only organise: the
  // tiles name graphics, not groups.
  function place(doc, name, toGroup, before) {
    if (name === before) {
      return doc;
    }
    const out = clone(doc);
    const at = find(out, name);
    delete out.groups[at.group].graphics[name];
    const group = out.groups[toGroup];
    const names = Object.keys(group.graphics);
    const i = before === null ? names.length : names.indexOf(before);
    names.splice(i < 0 ? names.length : i, 0, name);
    const graphics = {};
    for (const n of names) {
      graphics[n] = n === name ? at.g : group.graphics[n];
    }
    group.graphics = graphics;
    return out;
  }

  // The bitmap made `bytes` bytes wide and `rows` rows high: cut off, or
  // grown with clear pixels, at the right and the bottom.
  function setSize(doc, name, bytes, rows) {
    if (!Number.isInteger(bytes) || bytes < 1 || bytes > MAX_BYTES ||
        !Number.isInteger(rows) || rows < 2 || rows > MAX_ROWS || rows % 2) {
      throw new Error(`a graphic is 1 to ${MAX_BYTES} bytes wide and an even number of rows, 2 to ${MAX_ROWS}`);
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
    out.groups[name] = { graphics: {} };
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
    if (Object.keys(doc.groups[name].graphics).length) {
      throw new Error(`${name} still has graphics`);
    }
    const out = clone(doc);
    delete out.groups[name];
    return out;
  }

  return { MAX_BYTES, MAX_ROWS, STRIP, shiftInOf, shifted, parse, format, formatTiles, clone, find, badName, uses, setRows, addGraphic,
           removeGraphic, renameGraphic, place, setSize, addGroup, renameGroup, removeGroup };
}));
