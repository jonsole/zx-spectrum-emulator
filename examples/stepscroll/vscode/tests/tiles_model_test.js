// Tests for tiles_model.js -- the tiles editor's model of world/tiles.json
// (and of blocks.json, where a rename reaches it). Plain Node, no vscode API
// and no framework:
//
//   node examples/stepscroll/vscode/tests/tiles_model_test.js

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const W = require('../world_model');
const M = require('../tiles_model');

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

const tilesText = fs.readFileSync(path.join(WORLD, 'tiles.json'), 'utf8');
const blocksText = fs.readFileSync(path.join(WORLD, 'blocks.json'), 'utf8');
const blocksDoc = JSON.parse(blocksText);
const rows = JSON.parse(fs.readFileSync(path.join(WORLD, 'map.json'), 'utf8')).rows;

// Tiles picked from the data by what the tests need, not by name: one an
// entry draws (and the block it is in), one 2 bytes by 8 rows, and a group
// of at least 3 with another group beside it.
const data = JSON.parse(tilesText);
const all = Object.values(data.groups).flatMap((g) => Object.entries(g.tiles));
const USED_BLOCK = Object.keys(blocksDoc.blocks).find((b) => (blocksDoc.blocks[b].entries || []).length);
const USED = blocksDoc.blocks[USED_BLOCK].entries[0].tile;
const OTHER = all.map(([n]) => n).find((n) => n !== USED);
// A 2-byte tile with room to grow 2 rows (the data's own, whatever its height).
const T16x8 = all.find(([, g]) => g.rows[0].length === 16 && g.rows.length <= 20)[0];
const H = M.find(M.parse(tilesText), T16x8).g.rows.length;
const G3 = Object.keys(data.groups).find((g) => Object.keys(data.groups[g].tiles).length >= 3);
const G2 = Object.keys(data.groups).find((g) => g !== G3);
const lf = (s) => s.replace(/\r\n/g, '\n');

test('format writes tiles.json back as it was', () => {
  assert.strictEqual(M.format(M.parse(tilesText)), lf(tilesText));
  assert.strictEqual(M.format(M.parse(tilesText), '\r\n'), lf(tilesText).replace(/\n/g, '\r\n'));
});

test('formatBlocks writes blocks.json back as it was', () => {
  assert.strictEqual(M.formatBlocks(blocksDoc), lf(blocksText));
});

test('an edited pixel changes one line', () => {
  const doc = M.parse(tilesText);
  const r = M.find(doc, T16x8).g.rows.slice();
  r[3] = r[3].slice(0, 5) + (r[3][5] === '#' ? '.' : '#') + r[3].slice(6);
  const after = M.format(M.setRows(doc, T16x8, r)).split('\n');
  const before = lf(tilesText).split('\n');
  assert.strictEqual(after.length, before.length);
  assert.strictEqual(after.filter((line, i) => line !== before[i]).length, 1);
});

test('a rename reaches the blocks\' entries, and the world draws the same', () => {
  const doc = M.parse(tilesText);
  const { tiles, blocks } = M.renameTile(doc, blocksDoc, USED, 'grass');
  assert.ok(!M.find(tiles, USED));
  assert.ok(blocks.blocks[USED_BLOCK].entries.some((e) => e.tile === 'grass'));
  assert.ok(!JSON.stringify(blocks).includes(JSON.stringify(USED)));
  const a = W.render(blocksDoc.blocks, rows, W.parseTiles(doc));
  const b = W.render(blocks.blocks, rows, W.parseTiles(tiles));
  assert.ok(a.bits.every((v, i) => v === b.bits[i]));
  assert.throws(() => M.renameTile(doc, blocksDoc, USED, OTHER), /already a tile/);
});

test('a tile in use is not removed; one added, copied and removed again', () => {
  const doc = M.parse(tilesText);
  assert.throws(() => M.removeTile(doc, blocksDoc, USED), new RegExp(USED + ' is in use: block ' + USED_BLOCK));
  const added = M.addTile(doc, G3, 'new');
  assert.deepStrictEqual(M.find(added, 'new').g, { shiftIn: Array(8).fill('......'), rows: Array(8).fill('........') });
  const copied = M.addTile(added, G3, 'copy', USED);
  assert.deepStrictEqual(M.find(copied, 'copy').g, M.find(doc, USED).g);
  assert.ok(!M.find(M.removeTile(copied, blocksDoc, 'copy'), 'copy'));
});

test('setSize cuts and grows at the right and the bottom, within what an entry can draw', () => {
  const doc = M.parse(tilesText);
  const before = M.find(doc, T16x8).g.rows;      
  const big = M.find(M.setSize(doc, T16x8, 3, H + 2), T16x8).g.rows;
  assert.deepStrictEqual(big, before.map((r) => r + '........').concat(['.'.repeat(24), '.'.repeat(24)]));
  assert.deepStrictEqual(M.find(M.setSize(M.setSize(doc, T16x8, 3, H + 2), T16x8, 2, H),
                                T16x8).g.rows, before);
  assert.throws(() => M.setSize(doc, T16x8, 4, H), /1 to 3 bytes/);
  assert.throws(() => M.setSize(doc, T16x8, 2, H + 1), /even number of rows/);
  assert.throws(() => M.setSize(doc, T16x8, 2, 26), /2 to 24/);
});

test('the shifted versions are the tile moved right, its strip coming in on the left', () => {
  const g = { shiftIn: ['#.#..#', '......'], rows: ['########', '.#.#.#.#'] };
  assert.deepStrictEqual(M.shifted(g, 0), g.rows);
  assert.deepStrictEqual(M.shifted(g, 2), ['.#######', '...#.#.#']);
  assert.deepStrictEqual(M.shifted(g, 6), ['#.#..###', '.......#']);
  // setSize keeps the strip a row for each row.
  const doc = M.parse(tilesText);
  const g2 = M.find(M.setSize(doc, T16x8, 2, H + 2), T16x8).g;
  assert.strictEqual(g2.shiftIn.length, H + 2);
});

test('the shifted versions are what build.py draws', () => {
  const python = path.join(__dirname, '..', '..', '..', '..', '.venv-win', 'Scripts', 'python.exe');
  if (!fs.existsSync(python)) {
    console.log('skip -- no venv');
    return;
  }
  // build.py's tile() for one entry of each tile, as rows at each fine
  // position, against tiles_model's.
  const script = [
    'import json, build as B',
    'out = {}',
    'for name in B.BLOCKS:',
    '    for e in B.WORLD.entries(name):',
    '        if e.tile in out: continue',
    '        four = B.tile(e)',
    '        rows = []',
    '        for data in four:',
    '            lines = [None] * e.rows',
    '            k = 0',
    '            for i in range(e.rows - 1, 0, -2):',
    '                lines[i] = data[k:k + e.width]; k += e.width',
    '                lines[i - 1] = list(reversed(data[k:k + e.width])); k += e.width',
    '            rows.append(["".join(f"{b:08b}" for b in l).replace("0", ".").replace("1", "#") for l in lines])',
    '        out[e.tile] = rows',
    'print(json.dumps(out))',
  ].join('\n');
  const out = JSON.parse(require('child_process').execFileSync(python, ['-c', script], {
    cwd: path.join(__dirname, '..', '..'), encoding: 'utf8', maxBuffer: 1 << 26,
  }));
  const doc = M.parse(tilesText);
  let checked = 0;
  for (const [name, four] of Object.entries(out)) {
    const g = M.find(doc, name).g;
    [0, 2, 4, 6].forEach((fine, i) => assert.deepStrictEqual(M.shifted(g, fine), four[i], `${name} at ${fine}`));
    checked++;
  }
  assert.ok(checked > 90, checked + ' tiles');
});

test('shiftTile moves pixels round and round, the strip with the rows', () => {
  const doc = { groups: { g: { tiles: { A: { shiftIn: ['#.....', '.#....'], rows: ['#.......', '.......#'] } } } } };
  const right = M.find(M.shiftTile(doc, 'A', 1, 0), 'A').g;
  assert.deepStrictEqual(right, { shiftIn: ['#.....', '.#....'], rows: ['.#......', '#.......'] });
  const down = M.find(M.shiftTile(doc, 'A', 0, 1), 'A').g;
  assert.deepStrictEqual(down, { shiftIn: ['.#....', '#.....'], rows: ['.......#', '#.......'] });
  const back = M.shiftTile(M.shiftTile(M.shiftTile(doc, 'A', 1, 0), 'A', 0, 1), 'A', -1, -1);
  assert.deepStrictEqual(M.find(back, 'A').g, doc.groups.g.tiles.A);
});

test('place rearranges within a group and moves between groups', () => {
  const doc = M.parse(tilesText);
  const names = Object.keys(doc.groups[G3].tiles);
  const moved = M.place(doc, names[2], G3, names[0]);
  assert.deepStrictEqual(Object.keys(moved.groups[G3].tiles).slice(0, 3), [names[2], names[0], names[1]]);
  const across = M.place(doc, names[0], G2, null);
  assert.ok(!across.groups[G3].tiles[names[0]]);
  assert.strictEqual(Object.keys(across.groups[G2].tiles).pop(), names[0]);
  W.parseTiles(across);
});

test('groups: added, renamed, and only removed when empty', () => {
  let doc = M.parse(tilesText);
  doc = M.addGroup(doc, 'metal');
  assert.throws(() => M.addGroup(doc, G3), /already a group named/);
  doc = M.renameGroup(doc, G3, 'rocky');
  assert.ok(doc.groups.rocky && !doc.groups[G3]);
  assert.throws(() => M.removeGroup(doc, 'rocky'), /still has tiles/);
  assert.ok(!M.removeGroup(doc, 'metal').groups.metal);
});

console.log(failures ? failures + ' failed' : 'all passed');
process.exit(failures ? 1 : 0);
