// Tests for blocks_model.js -- the block editor's model of world/blocks.json
// (and map.json, where a block's rename reaches it). Plain Node:
//
//   node examples/stepscroll/vscode/tests/blocks_model_test.js

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const W = require('../world_model');
const T = require('../blocks_model');

const WORLD = path.join(__dirname, '..', '..', 'world');

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log('     ' + (err && err.stack ? err.stack : err));
  }
}

const read = (n) => fs.readFileSync(path.join(WORLD, n), 'utf8');
const lf = (s) => s.replace(/\r\n/g, '\n');
const blocksText = read('blocks.json');
const mapText = read('map.json');
const blocks = JSON.parse(blocksText);
const map = JSON.parse(mapText);
const tiles = W.parseTiles(JSON.parse(read('tiles.json')));

test('blocks.json and map.json are written back as they were', () => {
  assert.strictEqual(T.formatBlocks(blocks), lf(blocksText));
  assert.strictEqual(T.formatMap(map), lf(mapText));
});

test('a block renamed: the map follows; removing one on the map is refused', () => {
  const { blocks: t2, map: m2 } = T.renameBlock(blocks, map, 'hill', 'mound');
  assert.ok(t2.blocks.mound && !t2.blocks.hill);
  assert.deepStrictEqual(T.places(m2, 'mound'), T.places(map, 'hill'));
  assert.deepStrictEqual(Object.keys(t2.blocks).indexOf('mound'), Object.keys(blocks.blocks).indexOf('hill'));
  assert.throws(() => T.removeBlock(blocks, map, 'hill'), /hill is on the map 2 times/);
  const added = T.addBlock(blocks, 'new');
  assert.deepStrictEqual(added.blocks.new, { entries: [] });
  assert.ok(!T.removeBlock(added, map, 'new').blocks.new);
  assert.deepStrictEqual(T.addBlock(blocks, 'hill2', 'hill').blocks.hill2, blocks.blocks.hill);
  assert.throws(() => T.addBlock(blocks, 'hill'), /already a block named hill/);
});

// Two tiles of the test's own: A 3 bytes by 6 rows, B 3 bytes by 8.
const own = W.parseTiles({ groups: { g: { tiles: {
  A: { rows: Array(6).fill('#'.repeat(24)) },
  B: { rows: Array(8).fill('.'.repeat(24)) },
} } } });

test('entries snap to a byte column and an odd bottom line inside the page', () => {
  const g = own.tiles.A;
  assert.deepStrictEqual(T.snap(g, 4.4, 100), { column: 4, bottom: 101 });
  assert.deepStrictEqual(T.snap(g, 31, 300), { column: 29, bottom: 255 });
  assert.deepStrictEqual(T.snap(g, -3, 0), { column: 0, bottom: 5 });
});

test('entries added, moved, reordered, found and removed', () => {
  let t = T.addEntry(blocks, 'sky', own, 'A', 10, 120);
  assert.deepStrictEqual(t.blocks.sky.entries, [{ tile: 'A', column: 10, bottom: 121 }]);
  t = T.addEntry(t, 'sky', own, 'B', 11, 130);
  // B is 8 rows: lines 124 to 131 at columns 11 to 13.
  assert.strictEqual(T.entryAt(t, 'sky', own, 11 * 8, 124), 1);
  assert.strictEqual(T.entryAt(t, 'sky', own, 10 * 8, 120), 0);
  assert.strictEqual(T.entryAt(t, 'sky', own, 0, 0), -1);
  t = T.moveEntry(t, 'sky', own, 0, 20, 60);
  assert.deepStrictEqual(t.blocks.sky.entries[0], { tile: 'A', column: 20, bottom: 61 });
  const r = T.reorderEntry(t, 'sky', 0, 1);
  assert.strictEqual(r.index, 1);
  assert.strictEqual(r.blocks.blocks.sky.entries[1].tile, 'A');
  t = T.removeEntry(r.blocks, 'sky', 1);
  assert.deepStrictEqual(t.blocks.sky.entries.map((e) => e.tile), ['B']);
  assert.deepStrictEqual(W.blockProblems(t.blocks, 'sky', own), []);
});

console.log(failures ? failures + ' failed' : 'all passed');
process.exit(failures ? 1 : 0);
