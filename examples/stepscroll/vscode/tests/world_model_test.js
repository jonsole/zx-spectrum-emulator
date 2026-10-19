// Tests for world_model.js -- stepscroll's world drawn in JavaScript, for the
// designer's pages. Plain Node, no vscode API and no framework:
//
//   node examples/stepscroll/vscode/tests/world_model_test.js
//
// The picture is checked against world.py's own, pixel for pixel, on the real
// world/ files: world.py is run through the repo's venv (skipped without it).

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');
const W = require('../world_model');

const STEPSCROLL = path.join(__dirname, '..', '..');
const REPO = path.join(STEPSCROLL, '..', '..');
const WORLD = path.join(STEPSCROLL, 'world');
const PYTHON = path.join(REPO, '.venv-win', 'Scripts', 'python.exe');

let failures = 0;
let skipped = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    if (err && err.skip) {
      skipped++;
      console.log('skip ' + name + ' -- ' + err.message);
      return;
    }
    failures++;
    console.log('FAIL ' + name);
    console.log('     ' + (err && err.stack ? err.stack : err));
  }
}

function readJson(name) {
  return JSON.parse(fs.readFileSync(path.join(WORLD, name), 'utf8'));
}
const tiles = readJson('tiles.json').tiles;
const rows = readJson('map.json').rows;
const graphics = W.parseGraphics(readJson('steps.json'));

test('the world is world.py\'s, pixel for pixel', () => {
  if (!fs.existsSync(PYTHON)) {
    const err = new Error('no ' + PYTHON);
    err.skip = true;
    throw err;
  }
  const script = 'import sys, world; sys.stdout.write(world.load().bytes().tobytes().hex())';
  const hex = childProcess.execFileSync(PYTHON, ['-c', script], { cwd: STEPSCROLL, maxBuffer: 1 << 26, encoding: 'utf8' });
  const bytes = Buffer.from(hex, 'hex');
  const w = W.render(tiles, rows, graphics);
  assert.strictEqual(bytes.length * 8, w.width * w.height);
  let wrong = 0;
  for (let i = 0; i < bytes.length; i++) {
    for (let b = 0; b < 8; b++) {
      if (((bytes[i] >> (7 - b)) & 1) !== w.bits[i * 8 + b]) wrong++;
    }
  }
  assert.strictEqual(wrong, 0, wrong + ' pixels differ');
});

test('a mirrored tile\'s rock is its source\'s flipped', () => {
  const t = { a: tiles.dead_end_left, b: { from: 'a', mirrored: true }, s: { pieces: [] } };
  const one = W.render(t, [['a', 's', 's', 's', 's', 's', 's', 's']], null);
  const two = W.render(t, [['b', 's', 's', 's', 's', 's', 's', 's']], null);
  let wrong = 0;
  for (let y = 0; y < W.PAGE_H; y++) {
    for (let x = 0; x < W.PAGE_W; x++) {
      // The checker is on (x + y) even, which mirroring a 256-pixel page
      // turns odd; compare rock, not pixels: a pixel and its neighbour.
      const rockA = one.bits[y * one.width + x] | one.bits[y * one.width + (x ^ 1)];
      const xb = W.PAGE_W - 1 - x;
      const rockB = two.bits[y * two.width + xb] | two.bits[y * two.width + (xb ^ 1)];
      if (rockA !== rockB) wrong++;
    }
  }
  assert.ok(wrong < 64, wrong + ' pixels of rock differ');
});

test('tileProblems: none in the real tiles; an even line, an unknown graphic and one off the page found', () => {
  for (const name of Object.keys(tiles)) {
    assert.deepStrictEqual(W.tileProblems(tiles, name, graphics), [], name);
  }
  const t = { a: { pieces: [], entries: [{ graphic: 'floor-1-top', column: 0, bottom: 10 }] },
              b: { pieces: [], entries: [{ graphic: 'nothing', column: 0, bottom: 11 }] },
              c: { pieces: [], entries: [{ graphic: 'floor-1-top', column: 31, bottom: 11 }] } };
  assert.ok(W.tileProblems(t, 'a', graphics).some((p) => /even/.test(p)));
  assert.ok(W.tileProblems(t, 'b', graphics).some((p) => /no graphic "nothing"/.test(p)));
  assert.ok(W.tileProblems(t, 'c', graphics).some((p) => /leaves the page/.test(p)));
});

test('parseGraphics rejects a ragged bitmap and a stray character', () => {
  const doc = readJson('steps.json');
  doc.groups.floor.graphics['floor-1-top'].rows[0] += '#';
  assert.throws(() => W.parseGraphics(doc), /floor-1-top: rows/);
  const odd = readJson('steps.json');
  odd.groups.floor.graphics['floor-1-top'].rows[0] = '-' + odd.groups.floor.graphics['floor-1-top'].rows[0].slice(1);
  assert.throws(() => W.parseGraphics(odd), /floor-1-top: rows/);
});

console.log(failures ? failures + ' failed' : 'all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
process.exit(failures ? 1 : 0);
