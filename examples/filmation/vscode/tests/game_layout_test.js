// Tests for game_layout.js -- where a Filmation game keeps its files, and how
// far a path one of them names may reach. Plain Node:
//
//   node examples/filmation/vscode/tests/game_layout_test.js
//
// The bound is the part worth testing. A rooms.json in metadata/ names its
// picture as ../art/sprites.png, which the hosts have to follow; a path that
// climbs out of the game, or an absolute one, they must not. A castle laid out
// flat -- the way game-disassemblies' room editor hands one over -- keeps the
// bound it always had, its own directory.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const layout = require('../game_layout');

const FILMATION = path.join(__dirname, '..', '..');

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

// A game folder of each shape, made fresh: one with metadata/, art/ and
// generated/, one with everything at the top.
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'filmation-layout-'));
const SPLIT = path.join(ROOT, 'split');
const FLAT = path.join(ROOT, 'flat');
for (const dir of [path.join(SPLIT, 'metadata'), path.join(SPLIT, 'art'),
                   path.join(SPLIT, 'generated'), FLAT]) {
  fs.mkdirSync(dir, { recursive: true });
}

test('gameDirOf: the folder above metadata/, or the directory itself', () => {
  assert.strictEqual(layout.gameDirOf(path.join(SPLIT, 'metadata')), SPLIT);
  assert.strictEqual(layout.gameDirOf(FLAT), FLAT);
});

test('metadataOf, artOf and generatedOf: the folder when it is there, else the top', () => {
  assert.strictEqual(layout.metadataOf(SPLIT), path.join(SPLIT, 'metadata'));
  assert.strictEqual(layout.artOf(SPLIT), path.join(SPLIT, 'art'));
  assert.strictEqual(layout.generatedOf(SPLIT), path.join(SPLIT, 'generated'));
  assert.strictEqual(layout.metadataOf(FLAT), FLAT);
  assert.strictEqual(layout.artOf(FLAT), FLAT);
  assert.strictEqual(layout.generatedOf(FLAT), FLAT);
});

test('within: metadata/ may reach the rest of its game and no further', () => {
  const here = path.join(SPLIT, 'metadata');
  assert.strictEqual(layout.within(here, 'sprites.json'), path.join(here, 'sprites.json'));
  assert.strictEqual(layout.within(here, '../art/sprites.png'),
                     path.join(SPLIT, 'art', 'sprites.png'));
  assert.strictEqual(layout.within(here, '../../flat/rooms.json'), null, 'another game');
  assert.strictEqual(layout.within(here, '../../../x.png'), null);
  assert.strictEqual(layout.within(here, '..'), null, 'the game folder itself is no file');
  assert.strictEqual(layout.within(here, path.join(ROOT, 'flat', 'rooms.json')), null,
                     'an absolute path');
});

test('within: a flat game stays in its own directory, as it always did', () => {
  assert.strictEqual(layout.within(FLAT, 'sprites.png'), path.join(FLAT, 'sprites.png'));
  assert.strictEqual(layout.within(FLAT, '../split/art/sprites.png'), null);
  assert.strictEqual(layout.within(FLAT, '../art/sprites.png'), null);
});

test('within: a name that is not one is refused', () => {
  for (const junk of ['', null, undefined, 7]) {
    assert.strictEqual(layout.within(FLAT, junk), null, String(junk));
  }
});

// The shipped games are laid out the new way, and each file they name for
// another is one the hosts will follow.
test('the shipped games keep their JSON in metadata/ and name files the hosts follow', () => {
  for (const game of ['knightlore', 'pentagram', 'knightlore128', 'lightkeep']) {
    const dir = path.join(FILMATION, game);
    const here = layout.metadataOf(dir);
    assert.strictEqual(here, path.join(dir, 'metadata'), game);
    const rooms = JSON.parse(fs.readFileSync(path.join(here, 'rooms.json'), 'utf8'));
    for (const key of ['sheet', 'atlas', 'graphics']) {
      const file = layout.within(here, rooms.meta.sprites[key]);
      assert.ok(file && fs.existsSync(file), game + ': meta.sprites.' + key);
    }
    const sheet = JSON.parse(fs.readFileSync(path.join(here, 'sprites.json'), 'utf8'));
    const png = layout.within(here, sheet.sheet.file);
    assert.strictEqual(png, path.join(layout.artOf(dir), 'sprites.png'), game);
  }
});

fs.rmSync(ROOT, { recursive: true, force: true });

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
