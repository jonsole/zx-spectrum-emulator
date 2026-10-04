// Tests for graphic_map_model.js -- what a game's graphic table says, what it
// hides, and what an edit to one does. Plain Node, no vscode API and no
// framework:
//
//   node examples/filmation/vscode/tests/graphic_map_model_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" examples/filmation/vscode/tests/graphic_map_model_test.js)
//
// The document is examples/filmation/<game>/metadata/graphics.json -- which sprite each
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
const layout = require('../game_layout');
const sheetModel = require('../sheet_model');

const FILMATION = path.join(__dirname, '..', '..');
// Lightkeep's is the one that lists other sheets.
const GAMES = ['knightlore', 'pentagram', 'lightkeep'];

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

// A game's JSON, from its metadata/ -- or its top, for a game laid out flat.
function fileIn(game, leaf) {
  const file = path.join(layout.metadataOf(path.join(FILMATION, game)), leaf);
  if (!fs.existsSync(file)) skip(game + '/' + leaf + ' has not been unpacked');
  return fs.readFileSync(file, 'utf8');
}

function graphicsFor(game) {
  return m.parseMap(fileIn(game, 'graphics.json'));
}

function sheetFor(game) {
  return JSON.parse(fileIn(game, 'sprites.json'));
}

// The other sheets a game's graphics.json lists -- Lightkeep's Melkhior ones --
// by name, each read relative to graphics.json as the page's host reads them.
function othersFor(game) {
  const listed = sheetModel.sheetsOf(graphicsFor(game));
  const out = {};
  for (const name of Object.keys(listed)) out[name] = JSON.parse(fileIn(game, listed[name]));
  return out;
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

test('a sprite picked for a number the table has not got adds that graphic', () => {
  // The map is asked in the game's numbers; 2 is a gap. Picking a sprite for
  // it is how a graphic is added, named after the sprite -- with its number on
  // the end here, because a.1 is already graphic 0's name.
  const after = m.setSprite(TOY, 2, 'a.1');
  assert.deepStrictEqual(tableOf(after)['a.1.g2'], { number: 2, sprite: 'a.1' });
  assert.deepStrictEqual(tableOf(after)['a.1'], tableOf(TOY)['a.1'], 'graphic 0 untouched');
  assert.ok(!('a.1.g2' in tableOf(TOY)), 'a copy, not a change in place');
});

test('a sprite from another sheet makes a plain dotted name', () => {
  // A graphic's name is what rooms.json and the GFX_ labels use, and has no
  // sheet separator in it.
  const after = m.setSprite(TOY, 2, 'furniture:GrandfatherClockNE.2');
  assert.deepStrictEqual(tableOf(after)['furniture.GrandfatherClockNE.2'],
                         { number: 2, sprite: 'furniture:GrandfatherClockNE.2' });
});

test('taking the sprite off a number the table has not got changes nothing', () => {
  const after = m.setSprite(TOY, 2, null);
  assert.deepStrictEqual(Object.keys(tableOf(after)), Object.keys(tableOf(TOY)));
});

test('the other sheets: their sprites are named by sheet, and only the own sheet\'s are owed a graphic', () => {
  const said = JSON.parse(JSON.stringify(TOY));
  said.sheets = { objects: 'melkhior/objects.json' };
  said.graphics.bell = { number: 2, sprite: 'objects:Bell.0' };
  const others = { objects: { group: { Bell: { sprites: { 0: { x: 1, y: 13, w: 16, h: 20 } } },
                                       Key: { sprites: { 3: { x: 20, y: 13, w: 16, h: 8 } } } } } };
  const row = m.rows(said, SHEET, others)[2];
  assert.strictEqual(row.sprite, 'objects:Bell.0');
  assert.strictEqual(row.sheet, 'objects');
  assert.strictEqual(row.group, 'objects:Bell');
  assert.deepStrictEqual(row.rect, { x: 1, y: 13, w: 16, h: 20 });
  assert.strictEqual(row.dangling, false);
  // Without the other sheets, it is a name the page cannot find.
  assert.strictEqual(m.rows(said, SHEET)[2].dangling, true);
  // The unused Key is not a problem: the other sheets are a catalogue.
  assert.ok(!m.checkMap(said, SHEET, others).some((p) => /Key/.test(p)));
  const names = m.sheetSprites(SHEET, others).map((s) => s.name);
  assert.ok(names.includes('objects:Key.3') && names.includes('objects:Bell.0'));
  const sums = m.summary(said, SHEET, others);
  assert.strictEqual(sums.sheets, 1);
  assert.strictEqual(sums.fromSheets, 1);
});

test('a frame fits one sprite from 16 to 40 pixels wide and up to 64 high', () => {
  // engine/sprite.s has a blit for two to five bytes; redraw.s repaints 64 rows.
  assert.ok(m.fitsOneSprite({ w: 16, h: 1 }));
  assert.ok(m.fitsOneSprite({ w: 40, h: 64 }));
  assert.ok(!m.fitsOneSprite({ w: 8, h: 10 }), 'one byte has no blit');
  assert.ok(!m.fitsOneSprite({ w: 48, h: 10 }), 'six bytes is too wide');
  assert.ok(!m.fitsOneSprite({ w: 40, h: 65 }), '65 rows is too tall');
  assert.ok(!m.fitsOneSprite(null));
});

test('serializing carries the other sheets through, lined up', () => {
  const said = JSON.parse(JSON.stringify(TOY));
  said.sheets = { objects: 'melkhior/objects.json', characters: 'melkhior/characters.json' };
  const lines = m.serializeMap(said, '\n').split('\n');
  assert.deepStrictEqual(lines.slice(1, 6), [
    ' "sprites": "sprites.json",',
    ' "sheets": {',
    '  "objects":    "melkhior/objects.json",',
    '  "characters": "melkhior/characters.json"',
    ' },'
  ]);
  assert.deepStrictEqual(m.parseMap(m.serializeMap(said, '\n')).sheets, said.sheets);
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

// --- nudging, and the box -------------------------------------------------

test('a nudge is set per graphic, and the original is left alone', () => {
  const next = m.setNudge(TOY, 3, { x: -2, y: 11 }, false);
  assert.deepStrictEqual(m.nudgeOf(next, 3), { x: -2, y: 11, mirrored: null, note: null });
  assert.strictEqual(m.nudgeOf(next, 1).y, 2, 'graphic 1 draws the same bitmap and keeps its own');
  assert.strictEqual(m.nudgeOf(TOY, 3).y, 9, 'the table it was given changed');
});

test('a zero nudge is written as none', () => {
  const next = m.setNudge(TOY, 3, { x: 0, y: 0 }, false);
  assert.strictEqual(tableOf(next)['b.1.g3'].x, undefined);
  assert.strictEqual(tableOf(next)['b.1.g3'].y, undefined);
  assert.ok(/"b\.1\.g3": +\{ "number": +3, "sprite": "b\.1" *, "size": \{ "u": 3, "v": 5, "z": 40 \} \}/
    .test(m.serializeMap(next)), m.serializeMap(next));
});

test('the mirrored nudge is set and taken away on its own', () => {
  const given = m.setNudge(TOY, 4, { x: -9, y: 1 }, true);
  assert.deepStrictEqual(tableOf(given)['c.1.g4'].mirrored, { x: -9, y: 1 });
  assert.strictEqual(tableOf(given)['c.1.g4'].x, undefined, 'the plain one appeared');
  const taken = m.setNudge(TOY, 5, null, true);
  assert.strictEqual(tableOf(taken)['c.1.g5'].mirrored, undefined);
  assert.strictEqual(tableOf(taken)['c.1.g5'].x, 1, 'the plain one went with it');
});

test('nudging or boxing a number the table has not got changes nothing', () => {
  assert.deepStrictEqual(m.setNudge(TOY, 2, { x: 1, y: 1 }, false), TOY);
  assert.deepStrictEqual(m.setBox(TOY, 2, { u: 1, v: 1, z: 1 }), TOY);
});

test('a box is set and taken away, unmirrored', () => {
  const given = m.setBox(TOY, 4, { u: 2, v: 7, z: 12 });
  assert.deepStrictEqual(tableOf(given)['c.1.g4'].size, { u: 2, v: 7, z: 12 });
  assert.strictEqual(tableOf(TOY)['c.1.g4'].size, undefined, 'the table it was given changed');
  assert.strictEqual(tableOf(m.setBox(TOY, 1, null))['b.1.g1'].size, undefined);
});

test('a graphic with no box of its own is drawn in its sprite\'s first box', () => {
  const said = m.setBox(TOY, 1, null);
  // 1 has lost its box; 3 draws the same sprite and still has one.
  assert.deepStrictEqual(m.boxFor(said, 1), { box: { u: 3, v: 5, z: 40 }, from: 3 });
  assert.deepStrictEqual(m.boxFor(TOY, 1), { box: { u: 3, v: 5, z: 40 }, from: 1 });
  assert.strictEqual(m.boxFor(TOY, 4), null, 'c.1 has no box anywhere');
  assert.strictEqual(m.boxFor(TOY, 2), null, 'nothing is graphic 2');
});

test('the y nudge and the height lose a bit in a game of 512 graphic numbers', () => {
  // ADJ_Y holds y doubled over bit 8 of the graphic, and a template's height
  // carries the same bit in its bit 7.
  assert.deepStrictEqual(m.editLimits(TOY).y, { min: -128, max: 127 });
  assert.strictEqual(m.editLimits(TOY).z.max, 255);
  const big = m.setSprite(TOY, 300, 'a.1');
  assert.deepStrictEqual(m.editLimits(big).y, { min: -64, max: 63 });
  assert.strictEqual(m.editLimits(big).z.max, 127);
  assert.deepStrictEqual(m.editLimits(big).x, { min: -128, max: 127 }, 'x keeps its byte');
});

test('the box view: the corners are the projection\'s, relative to where it stands', () => {
  // floorPoint is x = U + V - 128 and y = 296 - ((V - U + 128) >> 1) - Z. At
  // U = V = 128 that is (128, 232); each corner is taken from there. With
  // half-widths 4 and 2 and a height of 10:
  //   corner 0, U-4 V-2:  x = -6, y = 64 - (130 >> 1) = -1
  //   corner 1, U+4 V-2:  x =  2, y = 64 - (122 >> 1) =  3
  //   corner 2, U-4 V+2:  x = -2, y = 64 - (134 >> 1) = -3
  //   corner 3, U+4 V+2:  x =  6, y = 64 - (126 >> 1) =  1
  // and 4 to 7 the same 10 rows up.
  const view = m.boxView({ x: -6, y: -3 }, { u: 4, v: 2, z: 10 }, { w: 16, h: 20 }, false);
  assert.deepStrictEqual(view.corners, [
    { x: -6, y: -1 }, { x: 2, y: 3 }, { x: -2, y: -3 }, { x: 6, y: 1 },
    { x: -6, y: -11 }, { x: 2, y: -7 }, { x: -2, y: -13 }, { x: 6, y: -9 }]);
  // The left column is the x nudge; the base is 3 rows BELOW the point,
  // because y is subtracted, so the top is 20 rows above that.
  assert.deepStrictEqual(view.sprite, { x: -6, y: -17, w: 16, h: 20, flipped: false });
  assert.deepStrictEqual(view.bounds, { minX: -6, minY: -17, maxX: 10, maxY: 3 });
  assert.deepStrictEqual(view.floor, [view.corners[0], view.corners[1],
                                      view.corners[3], view.corners[2]]);
});

test('the box view: twelve edges, and the three behind meet at the far corner', () => {
  const view = m.boxView(null, { u: 4, v: 2, z: 10 }, { w: 16, h: 20 }, false);
  assert.strictEqual(view.edges.length, 12);
  const hidden = view.edges.filter((e) => e.hidden).map((e) => [e.from, e.to]);
  assert.deepStrictEqual(hidden, [[0, 2], [2, 3], [2, 6]]);
  // The far corner is the highest of the four on the ground, which is what
  // makes it the one the box hides.
  const ground = view.corners.slice(0, 4).map((p) => p.y);
  assert.strictEqual(Math.min(...ground), view.corners[m.FAR_CORNER].y);
});

test('the box view: mirrored, the box turns and the picture is its mirror image', () => {
  const plain = m.boxView(null, { u: 4, v: 2, z: 10 }, { w: 16, h: 20 }, false);
  const flipped = m.boxView(null, { u: 4, v: 2, z: 10 }, { w: 16, h: 20 }, true);
  assert.strictEqual(flipped.sprite.flipped, true);
  // U and V swapped is the same box seen in a mirror: the ground corners are
  // the plain ones with x negated.
  const key = (p) => p.x + ',' + p.y;
  assert.deepStrictEqual(flipped.corners.map(key).sort(),
    plain.corners.map((p) => ({ x: -p.x, y: p.y })).map(key).sort());
});

test('the box view of a graphic with no box is the sprite and the point', () => {
  const view = m.boxView({ x: 2, y: 0 }, null, { w: 16, h: 8 }, false);
  assert.deepStrictEqual(view.corners, []);
  assert.deepStrictEqual(view.edges, []);
  assert.deepStrictEqual(view.bounds, { minX: 0, minY: -8, maxX: 18, maxY: 0 },
                         'the point it stands on is always in the picture');
});

test('a guessed box is as wide on the screen as the sprite', () => {
  // Half-widths of a quarter of 24, and 32 rows less the diamond's 12.
  const box = m.guessBox({ w: 24, h: 32 });
  assert.deepStrictEqual(box, { u: 6, v: 6, z: 20 });
  const view = m.boxView({ x: -12, y: 0 }, box, { w: 24, h: 32 }, false);
  const xs = view.corners.map((p) => p.x);
  assert.strictEqual(Math.max(...xs) - Math.min(...xs), 24);
});

test('knightlore: the doorways\' mirrored columns are the plain ones reflected', () => {
  // -(x + W): door.castle.1 is 24 wide at -7, so -17 mirrored. The rows are
  // one lower mirrored, which reflecting does not know -- hence a start.
  const graphics = graphicsFor('knightlore');
  const sheet = sheetFor('knightlore');
  const known = sheetModel.spritesByName(sheet);
  let doors = 0;
  for (const name of Object.keys(tableOf(graphics))) {
    const entry = tableOf(graphics)[name];
    if (!entry.mirrored) continue;
    const reflected = m.reflectedNudge(entry, known.get(entry.sprite).w);
    assert.strictEqual(reflected.x, entry.mirrored.x, name);
    assert.strictEqual(reflected.y, entry.y, name);
    doors++;
  }
  assert.strictEqual(doors, 4, 'Knight Lore has four graphics with a mirrored nudge');
});

// --- moving a graphic to another number -----------------------------------

test('a graphic moved to an unused number keeps its name, sprite and nudge', () => {
  const next = m.moveGraphic(TOY, 3, 2);
  assert.deepStrictEqual(tableOf(next)['b.1.g3'],
    { number: 2, sprite: 'b.1', size: { u: 3, v: 5, z: 40 }, x: -4, y: 9 });
  assert.strictEqual(m.rows(next, SHEET)[3].sprite, null, '3 is free now');
  assert.strictEqual(tableOf(TOY)['b.1.g3'].number, 3, 'the table it was given changed');
});

test('a graphic moved onto a used number swaps with it, and nothing else moves', () => {
  const next = m.moveGraphic(TOY, 4, 3);
  assert.strictEqual(tableOf(next)['c.1.g4'].number, 3);
  assert.strictEqual(tableOf(next)['b.1.g3'].number, 4);
  for (const name of ['a.1', 'b.1.g1', 'c.1.g5']) {
    assert.strictEqual(tableOf(next)[name].number, tableOf(TOY)[name].number, name);
  }
});

test('a fixed graphic does not move, and nothing is swapped onto one', () => {
  const said = JSON.parse(JSON.stringify(TOY));
  said.graphics['b.1.g3'].fixed = true;
  assert.strictEqual(m.isFixed(said, 3), true);
  assert.strictEqual(m.rows(said, SHEET)[3].fixed, true);
  assert.strictEqual(m.rows(said, SHEET)[4].fixed, false);
  assert.ok(/by its number/.test(m.whyNotMove(said, 3, 2)));
  assert.ok(/by its number/.test(m.whyNotMove(said, 4, 3)));
  assert.throws(() => m.moveGraphic(said, 3, 2), /by its number/);
  assert.strictEqual(m.whyNotMove(said, 4, 2), null);
});

test('a graphic cannot move to 0, 1, 256 or 257, nor past the game\'s numbers', () => {
  for (const to of [0, 1]) assert.ok(/never a graphic/.test(m.whyNotMove(TOY, 3, to)), to);
  // A table no wider than 256 is a game of 256 numbers.
  assert.strictEqual(m.numberLimit(TOY), 256);
  assert.ok(/past the 256/.test(m.whyNotMove(TOY, 3, 300)));
  const big = m.setSprite(TOY, 300, 'a.1');
  assert.strictEqual(m.numberLimit(big), 512);
  for (const to of [256, 257]) assert.ok(/never a graphic/.test(m.whyNotMove(big, 3, to)), to);
  assert.strictEqual(m.whyNotMove(big, 3, 258), null);
  assert.ok(/where it is/.test(m.whyNotMove(TOY, 3, 3)));
  assert.ok(/not in the table/.test(m.whyNotMove(TOY, 2, 6)));
});

test('"fixed" is written after the nudge, and only when it is true', () => {
  const said = m.setNudge(TOY, 5, { x: 1, y: -1 }, false);
  said.graphics['c.1.g5'].fixed = true;
  assert.ok(/"mirrored": \{ "x": -7, "y": -1 \}, "fixed": true \}/.test(m.serializeMap(said)));
  assert.strictEqual((m.serializeMap(TOY).match(/fixed/g) || []).length, 0);
});

test('every graphic the original games came with is fixed', () => {
  // Their code is the originals', and steps through frames by arithmetic on
  // the number. Knight Lore and Pentagram have nothing else.
  for (const game of ['knightlore', 'pentagram']) {
    const loose = m.rows(graphicsFor(game), sheetFor(game))
      .filter((r) => r.name !== null && !r.fixed).map((r) => r.name);
    assert.deepStrictEqual(loose, [], game);
  }
  // Lightkeep's movable ones are the scenery added since -- not the torches,
  // whose bottom two bits mover_cycle4 counts round.
  const loose = m.rows(graphicsFor('lightkeep'), sheetFor('lightkeep'), othersFor('lightkeep'))
    .filter((r) => r.name !== null && !r.fixed).map((r) => r.name);
  assert.deepStrictEqual(loose.sort(), ['castle.barrel.1', 'castle.bed.1', 'castle.bench.1',
    'castle.bridge.deck', 'castle.bridge.rail', 'castle.chair.1', 'castle.parapet.1',
    'castle.shelf.1', 'doors.DoorSide1.0', 'doors.DoorSide1.1', 'doors.DoorTop1.0', 'solid']);
});

// --- the real files -------------------------------------------------------

for (const game of GAMES) {
  test(game + ': the real table round-trips through parse and serialize', () => {
    // The panel writes whole documents. If writing one back unchanged changed
    // anything, every edit would carry the reflow of the whole file with it --
    // and examples/filmation/scripts/graphics.py's format_table, which writes the same
    // layout from the other side, would fight it.
    const text = fileIn(game, 'graphics.json');
    const eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    assert.strictEqual(m.serializeMap(m.parseMap(text), eol), text,
                       'writing it back unchanged should change nothing');
  });

  test(game + ': the real table has nothing wrong with it', () => {
    const problems = m.checkMap(graphicsFor(game), sheetFor(game), othersFor(game))
      // Sprites no graphic draws are a fact about the game, not a fault: the
      // rotation buffers and a few panel pieces are reached directly.
      .filter((p) => !/no graphic number draws/.test(p));
    assert.deepStrictEqual(problems, []);
  });

  test(game + ': every graphic resolves to artwork on the sheet', () => {
    const list = m.rows(graphicsFor(game), sheetFor(game), othersFor(game));
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
