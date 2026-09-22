// Tests for graphic_map_model.js -- what a game's graphic table says, what it
// hides, and what an edit to one does. Plain Node, no vscode API and no
// framework:
//
//   node examples/filmation/vscode/tests/graphic_map_model_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" examples/filmation/vscode/tests/graphic_map_model_test.js)
//
// The document is examples/filmation/<game>/graphics.json -- which sprite each
// graphic number draws, the nudge that lines it up, and the box it occupies.
// sprites.json is read alongside, for the pictures and the names, and is not
// edited here; both are passed in, in that order. The small tests stand on
// their own: a table and a sheet are written out by hand and the expected
// answers worked out from what they mean, not read back out of the model. The
// rest run against the two games' real files.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const m = require('../graphic_map_model');

const FILMATION = path.join(__dirname, '..', '..');
const GAMES = ['knightlore', 'pentagram'];

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
    console.log(err.stack);
  }
}

function skip(why) {
  const err = new Error(why);
  err.skip = true;
  throw err;
}

function fileIn(game, leaf) {
  const file = path.join(FILMATION, game, leaf);
  if (!fs.existsSync(file)) skip(game + '/' + leaf + ' has not been unpacked');
  return fs.readFileSync(file, 'utf8');
}

function graphicsFor(game) {
  return m.parseMap(fileIn(game, 'graphics.json'));
}

function sheetFor(game) {
  return JSON.parse(fileIn(game, 'sprites.json'));
}

// A sheet small enough to reason about: three sprites, one to a group, named
// by where they sit -- a.1 is the sprite called "1" in the group "a".
function toySheet() {
  return {
    sheet: { file: 'sprites.png' },
    group: {
      a: { sprites: { 1: { x: 0, y: 0, w: 8, h: 8 } } },
      b: { sprites: { 1: { x: 8, y: 0, w: 8, h: 8 } } },
      c: { sprites: { 1: { x: 16, y: 0, w: 8, h: 8 } } }
    }
  };
}

// ...and a table over it: five graphic numbers over three sprites, two pairs
// of them sharing, and a gap at 2 the game does not use. Graphic 3 is nudged
// differently from 1 although they draw the same bitmap, which is the whole
// reason the nudge sits on the graphic rather than on the sprite. 1 and 3 also
// carry a box, which is the graphic's rather than the template's.
//
// Keyed by the graphic's NAME, with the number the game knows it by as a
// field. rooms.json refers to graphics by those names, so they have to be
// written down somewhere, and this is the somewhere.
function toyTable() {
  return {
    sprites: 'sprites.json',
    graphics: {
      'a.1': { number: 0, sprite: 'a.1' },
      'b.1.g1': { number: 1, sprite: 'b.1', size: { u: 3, v: 5, z: 40 },
        x: -4, y: 2 },
      'b.1.g3': { number: 3, sprite: 'b.1', size: { u: 3, v: 5, z: 40 },
        x: -4, y: 9 },
      'c.1.g4': { number: 4, sprite: 'c.1' },
      'c.1.g5': { number: 5, sprite: 'c.1', x: 1, y: -1,
        mirrored: { x: -7, y: -1 } }
    }
  };
}

const SHEET = toySheet();
const TOY = toyTable();

function tableOf(said) {
  return said.graphics;
}

// --- what the table says --------------------------------------------------

test('a gap in the table is a graphic the game does not use', () => {
  const table = m.spriteOf(TOY);
  assert.strictEqual(table.size, 5);
  assert.strictEqual(table.has(2), false);
  assert.strictEqual(table.get(3), 'b.1');
});

test('the count is the width of the table, not how much of it is used', () => {
  // One past the highest number named: the game's own table was wider, but
  // nothing reads past the last graphic that draws something.
  assert.strictEqual(m.countOf(TOY), 6);
  assert.strictEqual(m.spriteOf(TOY).size, 5);
});

test('a sprite named by number is the packed form leaking through', () => {
  // The old .bin said 255 for "no sprite". Sprites are named now, so a number
  // here means a file converted by hand and half-done -- caught rather than
  // quietly believed.
  const said = toyTable();
  said.graphics['b.1.g1'].sprite = m.NO_SPRITE;
  assert.strictEqual(m.spriteOf(said).has(1), false);
  assert.ok(m.checkMap(said, SHEET).some((p) => /a number/.test(p)));
});

test('sharing is read back out: which numbers draw the same sprite', () => {
  const shares = m.sharedBy(TOY);
  assert.deepStrictEqual(shares.get('b.1'), [1, 3]);
  assert.deepStrictEqual(shares.get('c.1'), [4, 5]);
  assert.deepStrictEqual(shares.get('a.1'), [0]);
});

test('a row knows what else shares its sprite, but not itself', () => {
  const list = m.rows(TOY, SHEET);
  assert.strictEqual(list.length, 6);
  assert.deepStrictEqual(list[1].sharedWith, [3]);
  assert.deepStrictEqual(list[3].sharedWith, [1]);
  assert.deepStrictEqual(list[0].sharedWith, []);
  assert.strictEqual(list[1].sprite, 'b.1');
  assert.strictEqual(list[1].group, 'b');
  // The unused number is still a row, so there is somewhere to put one.
  assert.strictEqual(list[2].sprite, null);
  assert.strictEqual(list[2].rect, null);
});

test('two graphics drawing one bitmap are still two graphics', () => {
  // 1 and 3 name the same sprite and come out of the same rectangle, and they
  // are NOT interchangeable: the nudge is per number, and these two put that
  // bitmap seven rows apart.
  const list = m.rows(TOY, SHEET);
  assert.strictEqual(list[1].sprite, list[3].sprite);
  assert.deepStrictEqual(list[1].rect, list[3].rect);
  assert.notStrictEqual(list[1].nudge.y, list[3].nudge.y);
});

test('a sprite the sheet has not got is dangling, not empty', () => {
  const said = toyTable();
  said.graphics['b.1.g1'].sprite = 'nowhere.9';
  const list = m.rows(said, SHEET);
  assert.strictEqual(list[1].dangling, true);
  assert.strictEqual(list[1].rect, null);
  assert.strictEqual(list[0].dangling, false);
  // An unused number is not dangling: it names nothing, rather than naming
  // something that is missing.
  assert.strictEqual(m.rows(TOY, SHEET)[2].dangling, false);
  assert.ok(m.checkMap(said, SHEET).some((p) => /nowhere\.9/.test(p)));
});

// --- editing --------------------------------------------------------------

test('re-pointing a graphic leaves the original alone', () => {
  const before = JSON.stringify(TOY);
  const after = m.setSprite(TOY, 1, 'c.1');
  assert.strictEqual(JSON.stringify(TOY), before, 'the input was mutated');
  assert.strictEqual(tableOf(after)['b.1.g1'].sprite, 'c.1');
  assert.strictEqual(tableOf(after)['b.1.g3'].sprite, 'b.1',
                     'the one that shared it is untouched');
});

test('re-pointing keeps the nudge, which cannot be got back', () => {
  // It was harvested by adj.py from a RUNNING game; the sprite can be
  // re-extracted from a snapshot any time. Losing the one on a click that
  // changes the other would be losing the only copy there is.
  const after = m.setSprite(TOY, 1, 'c.1');
  assert.strictEqual(tableOf(after)['b.1.g1'].x, -4);
  assert.strictEqual(tableOf(after)['b.1.g1'].y, 2);

  const gone = m.setSprite(TOY, 5, null);
  assert.strictEqual(tableOf(gone)['c.1.g5'].sprite, undefined, 'the sprite went');
  assert.strictEqual(tableOf(gone)['c.1.g5'].x, 1, 'the nudge stayed');
  assert.deepStrictEqual(tableOf(gone)['c.1.g5'].mirrored, { x: -7, y: -1 });
});

test('re-pointing keeps the box, which is the graphic\'s own', () => {
  // The box is what the engine sorts and collides with, and it belongs to the
  // graphic rather than to the bitmap: drawing it with a different sprite does
  // not make it a different size.
  const after = m.setSprite(TOY, 1, 'c.1');
  assert.deepStrictEqual(tableOf(after)['b.1.g1'].size, { u: 3, v: 5, z: 40 });
});

test('re-pointing a graphic does NOT rename it', () => {
  // The name is what rooms.json refers to the graphic by. Working it out from
  // the sprite would make "draw this with a different bitmap" a rename, and
  // every castle that placed it would dangle.
  const after = m.setSprite(TOY, 1, 'c.1');
  assert.deepStrictEqual(Object.keys(tableOf(after)),
                         ['a.1', 'b.1.g1', 'b.1.g3', 'c.1.g4', 'c.1.g5']);
  assert.strictEqual(tableOf(after)['b.1.g1'].number, 1, 'and keeps its number');
});

test('a graphic the table has not got is left alone', () => {
  // The map is asked in the game's numbers; 2 is a gap.
  const after = m.setSprite(TOY, 2, 'a.1');
  assert.deepStrictEqual(Object.keys(tableOf(after)), Object.keys(tableOf(TOY)));
});

test('serializing keeps the file\'s own line endings', () => {
  const unix = m.serializeMap(TOY, '\n');
  const dos = m.serializeMap(TOY, '\r\n');
  assert.ok(!unix.includes('\r'));
  assert.ok(dos.includes('\r\n'));
  assert.strictEqual(dos.replace(/\r\n/g, '\n'), unix);
  assert.ok(unix.endsWith('\n'));
});

test('serializing lays the table out a graphic to a line', () => {
  // The file is one people edit by hand. A panel that wrote it back as
  // JSON.stringify would reflow all 187 lines the first time a graphic was
  // re-pointed, and every change would diff as the whole file.
  const lines = m.serializeMap(TOY, '\n').split('\n');
  assert.strictEqual(lines[1], ' "sprites": "sprites.json",');
  assert.strictEqual(lines[2], ' "graphics": {');
  assert.strictEqual(
    lines[3], '  "a.1":    { "number":   0, "sprite": "a.1" },');
  assert.strictEqual(
    lines[4],
    '  "b.1.g1": { "number":   1, "sprite": "b.1", ' +
    '"size": { "u": 3, "v": 5, "z": 40 }, "x": -4, "y": 2 },');
  // The last one carries no comma, and the file ends on one newline.
  assert.strictEqual(lines[lines.length - 3], ' }');
  assert.strictEqual(lines[lines.length - 2], '}');
  assert.strictEqual(lines[lines.length - 1], '');
});

test('the nudge is read back per graphic, not per sprite', () => {
  assert.strictEqual(m.spriteOf(TOY).get(1), m.spriteOf(TOY).get(3));
  assert.strictEqual(m.nudgeOf(TOY, 1).y, 2);
  assert.strictEqual(m.nudgeOf(TOY, 3).y, 9);
  assert.strictEqual(m.nudgeOf(TOY, 0), null, 'no nudge is null, not zero');
  assert.deepStrictEqual(m.nudgeOf(TOY, 5).mirrored, { x: -7, y: -1 });
  assert.strictEqual(m.rows(TOY, SHEET)[3].nudge.y, 9);
});

test('a graphic can be nudged with no sprite at all', () => {
  // Knight Lore's graphic 1 is exactly this, and it is not a fault.
  const said = { sprites: 'sprites.json',
    graphics: { 'gfx_01': { number: 1, x: -12, y: -8 } } };
  assert.strictEqual(m.spriteOf(said).has(1), false);
  assert.strictEqual(m.nudgeOf(said, 1).x, -12);
  assert.deepStrictEqual(
    m.checkMap(said, SHEET).filter((p) => /Graphic 1\b/.test(p)), []);
  const list = m.rows(said, SHEET);
  assert.strictEqual(list[1].sprite, null);
  assert.strictEqual(list[1].dangling, false);
});

// --- the real files -------------------------------------------------------

for (const game of GAMES) {
  test(game + ': the real table round-trips through parse and serialize', () => {
    // The panel writes whole documents. If writing one back unchanged changed
    // anything, every edit would carry the reflow of the whole file with it --
    // and examples/filmation/graphics.py's format_table, which writes the same
    // layout from the other side, would fight it.
    const text = fileIn(game, 'graphics.json');
    const eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    assert.strictEqual(m.serializeMap(m.parseMap(text), eol), text,
                       'writing it back unchanged should change nothing');
  });

  test(game + ': the real table has nothing wrong with it', () => {
    const problems = m.checkMap(graphicsFor(game), sheetFor(game))
      // Sprites no graphic draws are a fact about the game, not a fault: the
      // rotation buffers and a few panel pieces are reached directly.
      .filter((p) => !/no graphic number draws/.test(p));
    assert.deepStrictEqual(problems, []);
  });

  test(game + ': every graphic resolves to artwork on the sheet', () => {
    const list = m.rows(graphicsFor(game), sheetFor(game));
    assert.deepStrictEqual(list.filter((r) => r.dangling).map((r) => r.graphic), []);
    assert.ok(list.filter((r) => r.rect).length > 100);
  });
}

test('knightlore: the documented figures are what the files hold', () => {
  // 186 valid graphics over 103 sprites is quoted in README.md, in
  // examples/filmation/room-designer.md and in the files' own comments.
  const sums = m.summary(graphicsFor('knightlore'), sheetFor('knightlore'));
  assert.strictEqual(sums.used, 186);
  assert.strictEqual(sums.sprites, 103);
  assert.strictEqual(sums.onSheet, 103);
});

test('knightlore: 30 and 150 share a bitmap and sit four rows apart', () => {
  const graphics = graphicsFor('knightlore');
  const table = m.spriteOf(graphics);
  assert.strictEqual(table.get(30), table.get(150),
                     'they are documented as the same bitmap');
  // Y is subtracted from the base row, so the larger draws the higher: 150 at
  // 7 sits four rows above 30 at 3. That is why they are not interchangeable,
  // and why the nudge belongs on the graphic rather than on the sprite.
  assert.strictEqual(m.nudgeOf(graphics, 30).y, 3);
  assert.strictEqual(m.nudgeOf(graphics, 150).y, 7);
  assert.strictEqual(m.nudgeOf(graphics, 30).x, m.nudgeOf(graphics, 150).x,
                     'they differ only in the row');
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
