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
const blocks = readJson('blocks.json').blocks;
const rows = readJson('map.json').rows;
const tiles = W.parseTiles(readJson('tiles.json'));

test('the world is world.py\'s, pixel for pixel', () => {
  if (!fs.existsSync(PYTHON)) {
    const err = new Error('no ' + PYTHON);
    err.skip = true;
    throw err;
  }
  const script = 'import sys, world; sys.stdout.write(world.load().bytes().tobytes().hex())';
  const hex = childProcess.execFileSync(PYTHON, ['-c', script], { cwd: STEPSCROLL, maxBuffer: 1 << 26, encoding: 'utf8' });
  const bytes = Buffer.from(hex, 'hex');
  const w = W.render(blocks, rows, tiles);
  assert.strictEqual(bytes.length * 8, w.width * w.height);
  let wrong = 0;
  for (let i = 0; i < bytes.length; i++) {
    for (let b = 0; b < 8; b++) {
      if (((bytes[i] >> (7 - b)) & 1) !== w.bits[i * 8 + b]) wrong++;
    }
  }
  assert.strictEqual(wrong, 0, wrong + ' pixels differ');
});

test('coverageGaps finds the bytes build.py\'s coverage check does', () => {
  if (!fs.existsSync(PYTHON)) {
    const err = new Error('no ' + PYTHON);
    err.skip = true;
    throw err;
  }
  // build.py's NEED and FOOT: every byte a move changes, less those an entry
  // draws, as (line, column) pairs.
  const script = 'import json, numpy as np, build as B\n' +
    'g = np.zeros_like(B.FOOT)\n' +
    'for v in B.NEED.values(): g |= v & ~B.FOOT\n' +
    'print(json.dumps([[int(y), int(x)] for y, x in np.argwhere(g)]))';
  const out = JSON.parse(childProcess.execFileSync(PYTHON, ['-c', script],
    { cwd: STEPSCROLL, encoding: 'utf8', maxBuffer: 1 << 26 }));
  const w = W.render(blocks, rows, tiles);
  const gaps = W.coverageGaps(w);
  const got = [];
  gaps.forEach((v, i) => { if (v) got.push([Math.floor(i / 256), i % 256]); });
  assert.deepStrictEqual(got, out);
  console.log('     (' + got.length + ' bytes)');
});

test('blockProblems: none in the real blocks; an even line, an unknown tile and one off the page found', () => {
  for (const name of Object.keys(blocks)) {
    assert.deepStrictEqual(W.blockProblems(blocks, name, tiles), [], name);
  }
  const own = W.parseTiles({ groups: { g: { tiles: { A: { rows: Array(6).fill('#'.repeat(24)) } } } } });
  const t = { a: { entries: [{ tile: 'A', column: 0, bottom: 10 }] },
              b: { entries: [{ tile: 'nothing', column: 0, bottom: 11 }] },
              c: { entries: [{ tile: 'A', column: 31, bottom: 11 }] } };
  assert.ok(W.blockProblems(t, 'a', own).some((p) => /even/.test(p)));
  assert.ok(W.blockProblems(t, 'b', own).some((p) => /no tile "nothing"/.test(p)));
  assert.ok(W.blockProblems(t, 'c', own).some((p) => /leaves the page/.test(p)));
});

test('parseTiles rejects a ragged bitmap and a stray character', () => {
  const doc = () => ({ groups: { g: { tiles: { A: { rows: Array(6).fill('#'.repeat(24)) } } } } });
  const ragged = doc();
  ragged.groups.g.tiles.A.rows[0] += '#';
  assert.throws(() => W.parseTiles(ragged), /A: rows/);
  const stray = doc();
  stray.groups.g.tiles.A.rows[0] = '-' + stray.groups.g.tiles.A.rows[0].slice(1);
  assert.throws(() => W.parseTiles(stray), /A: rows/);
});

console.log(failures ? failures + ' failed' : 'all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
process.exit(failures ? 1 : 0);
