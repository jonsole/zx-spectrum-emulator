// Tests for steps_model.js -- the graphics editor's model of world/steps.json
// (and of tiles.json, where a rename reaches it). Plain Node, no vscode API
// and no framework:
//
//   node examples/stepscroll/vscode/tests/steps_model_test.js

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const W = require('../world_model');
const M = require('../steps_model');

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

const stepsText = fs.readFileSync(path.join(WORLD, 'steps.json'), 'utf8');
const tilesText = fs.readFileSync(path.join(WORLD, 'tiles.json'), 'utf8');
const tilesDoc = JSON.parse(tilesText);
const rows = JSON.parse(fs.readFileSync(path.join(WORLD, 'map.json'), 'utf8')).rows;
const lf = (s) => s.replace(/\r\n/g, '\n');

test('format writes steps.json back as it was', () => {
  assert.strictEqual(M.format(M.parse(stepsText)), lf(stepsText));
  assert.strictEqual(M.format(M.parse(stepsText), '\r\n'), lf(stepsText).replace(/\n/g, '\r\n'));
});

test('formatTiles writes tiles.json back as it was', () => {
  assert.strictEqual(M.formatTiles(tilesDoc), lf(tilesText));
});

test('an edited pixel changes one line', () => {
  const doc = M.parse(stepsText);
  const r = M.find(doc, 'floor-up-3').g.rows.slice();
  r[3] = r[3].slice(0, 5) + (r[3][5] === '#' ? '.' : '#') + r[3].slice(6);
  const after = M.format(M.setRows(doc, 'floor-up-3', r)).split('\n');
  const before = lf(stepsText).split('\n');
  assert.strictEqual(after.length, before.length);
  assert.strictEqual(after.filter((line, i) => line !== before[i]).length, 1);
});

test('a rename reaches the tiles\' entries, and the world draws the same', () => {
  const doc = M.parse(stepsText);
  const { steps, tiles } = M.renameGraphic(doc, tilesDoc, 'floor-1-top', 'grass');
  assert.ok(!M.find(steps, 'floor-1-top'));
  assert.ok(tiles.tiles.plain.entries.some((e) => e.graphic === 'grass'));
  assert.ok(!JSON.stringify(tiles).includes('"floor-1-top"'));
  const a = W.render(tilesDoc.tiles, rows, W.parseGraphics(doc));
  const b = W.render(tiles.tiles, rows, W.parseGraphics(steps));
  assert.ok(a.bits.every((v, i) => v === b.bits[i]));
  assert.throws(() => M.renameGraphic(doc, tilesDoc, 'floor-1-top', 'floor-1-top-bottom'), /already a graphic/);
});

test('a graphic in use is not removed; one added, copied and removed again', () => {
  const doc = M.parse(stepsText);
  assert.throws(() => M.removeGraphic(doc, tilesDoc, 'floor-1-top'), /floor-1-top is in use: tile plain/);
  const added = M.addGraphic(doc, 'floor', 'new');
  assert.deepStrictEqual(M.find(added, 'new').g, { shiftIn: Array(8).fill('......'), rows: Array(8).fill('........') });
  const copied = M.addGraphic(added, 'floor', 'copy', 'floor-1-top');
  assert.deepStrictEqual(M.find(copied, 'copy').g, M.find(doc, 'floor-1-top').g);
  assert.ok(!M.find(M.removeGraphic(copied, tilesDoc, 'copy'), 'copy'));
});

test('setSize cuts and grows at the right and the bottom, within what an entry can draw', () => {
  const doc = M.parse(stepsText);
  const before = M.find(doc, 'floor-up-3').g.rows;      // 16 x 8
  const big = M.find(M.setSize(doc, 'floor-up-3', 3, 10), 'floor-up-3').g.rows;
  assert.deepStrictEqual(big, before.map((r) => r + '........').concat(['.'.repeat(24), '.'.repeat(24)]));
  assert.deepStrictEqual(M.find(M.setSize(M.setSize(doc, 'floor-up-3', 3, 10), 'floor-up-3', 2, 8),
                                'floor-up-3').g.rows, before);
  assert.throws(() => M.setSize(doc, 'floor-up-3', 4, 8), /1 to 3 bytes/);
  assert.throws(() => M.setSize(doc, 'floor-up-3', 2, 9), /even number of rows/);
  assert.throws(() => M.setSize(doc, 'floor-up-3', 2, 18), /2 to 16/);
});

test('the shifted versions are the graphic moved right, its strip coming in on the left', () => {
  const g = { shiftIn: ['#.#..#', '......'], rows: ['########', '.#.#.#.#'] };
  assert.deepStrictEqual(M.shifted(g, 0), g.rows);
  assert.deepStrictEqual(M.shifted(g, 2), ['.#######', '...#.#.#']);
  assert.deepStrictEqual(M.shifted(g, 6), ['#.#..###', '.......#']);
  // setSize keeps the strip a row for each row.
  const doc = M.parse(stepsText);
  const g2 = M.find(M.setSize(doc, 'floor-up-3', 2, 12), 'floor-up-3').g;
  assert.strictEqual(g2.shiftIn.length, 12);
});

test('the shifted versions are what build.py draws', () => {
  const python = path.join(__dirname, '..', '..', '..', '..', '.venv-win', 'Scripts', 'python.exe');
  if (!fs.existsSync(python)) {
    console.log('skip -- no venv');
    return;
  }
  // build.py's graphic() for one entry of each graphic, as rows at each fine
  // position, against steps_model's.
  const script = [
    'import json, build as B',
    'out = {}',
    'for name in B.TILES:',
    '    for e in B.WORLD.entries(name):',
    '        if e.graphic in out: continue',
    '        four = B.graphic(e)',
    '        rows = []',
    '        for data in four:',
    '            lines = [None] * e.rows',
    '            k = 0',
    '            for i in range(e.rows - 1, 0, -2):',
    '                lines[i] = data[k:k + e.width]; k += e.width',
    '                lines[i - 1] = list(reversed(data[k:k + e.width])); k += e.width',
    '            rows.append(["".join(f"{b:08b}" for b in l).replace("0", ".").replace("1", "#") for l in lines])',
    '        out[e.graphic] = rows',
    'print(json.dumps(out))',
  ].join('\n');
  const out = JSON.parse(require('child_process').execFileSync(python, ['-c', script], {
    cwd: path.join(__dirname, '..', '..'), encoding: 'utf8', maxBuffer: 1 << 26,
  }));
  const doc = M.parse(stepsText);
  let checked = 0;
  for (const [name, four] of Object.entries(out)) {
    const g = M.find(doc, name).g;
    [0, 2, 4, 6].forEach((fine, i) => assert.deepStrictEqual(M.shifted(g, fine), four[i], `${name} at ${fine}`));
    checked++;
  }
  assert.ok(checked > 90, checked + ' graphics');
});

test('place rearranges within a group and moves between groups', () => {
  const doc = M.parse(stepsText);
  const names = Object.keys(doc.groups.floor.graphics);
  const moved = M.place(doc, names[2], 'floor', names[0]);
  assert.deepStrictEqual(Object.keys(moved.groups.floor.graphics).slice(0, 3), [names[2], names[0], names[1]]);
  const across = M.place(doc, names[0], 'ceiling', null);
  assert.ok(!across.groups.floor.graphics[names[0]]);
  assert.strictEqual(Object.keys(across.groups.ceiling.graphics).pop(), names[0]);
  W.parseGraphics(across);
});

test('groups: added, renamed, and only removed when empty', () => {
  let doc = M.parse(stepsText);
  doc = M.addGroup(doc, 'metal');
  assert.throws(() => M.addGroup(doc, 'floor'), /already a group named floor/);
  doc = M.renameGroup(doc, 'floor', 'rocky');
  assert.ok(doc.groups.rocky && !doc.groups.floor);
  assert.throws(() => M.removeGroup(doc, 'rocky'), /still has graphics/);
  assert.ok(!M.removeGroup(doc, 'metal').groups.metal);
});

console.log(failures ? failures + ' failed' : 'all passed');
process.exit(failures ? 1 : 0);
