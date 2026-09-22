// Tests for specials_model.js -- where Knight Lore's collectables start, what
// the game will actually place, and what an edit does. Plain Node:
//
//   node examples/filmation/vscode/tests/specials_model_test.js
//
// The constants are checked against knightlore/special.s rather than repeated
// from memory: they are the game's, and a model that disagreed with them would
// draw a box the game does not sort by and count slots the game does not have.
// The rest runs against the real specials.json.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const m = require('../specials_model');

const FILMATION = path.join(__dirname, '..', '..');
const KNIGHTLORE = path.join(FILMATION, 'knightlore');

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

function realSpecials() {
  const file = path.join(KNIGHTLORE, 'specials.json');
  if (!fs.existsSync(file)) skip('knightlore/specials.json is not here');
  return m.parseSpecials(fs.readFileSync(file, 'utf8'));
}

function toy(overrides) {
  const list = [];
  for (let i = 0; i < m.ROWS; i++) {
    list.push({ room: i, u: 128, v: 128, z: 64 });
  }
  return Object.assign({
    game: 'knightlore',
    collectables: list,
    wanted: [0, 1, 2, 3, 4, 5, 6, 3, 5, 0, 6, 1, 2, 4]
  }, overrides || {});
}

// --- the game's own numbers -----------------------------------------------

test('the constants are the ones special.s defines', () => {
  const file = path.join(KNIGHTLORE, 'special.s');
  if (!fs.existsSync(file)) skip('knightlore/special.s is not here');
  const source = fs.readFileSync(file, 'utf8');
  // A constant is either a plain number or a GFX_* label -- the graphic
  // numbers come from graphics.json now, through the generated graphics_gen.s,
  // so the sources name the graphic instead of spelling its number out. Follow
  // the label where there is one: what this checks is that the model and the
  // game agree on the number, however the game says it.
  const labels = path.join(KNIGHTLORE, 'graphics_gen.s');
  const generated = fs.existsSync(labels) ? fs.readFileSync(labels, 'utf8') : '';
  const equ = (name) => {
    const found = source.match(
      new RegExp('^' + name + '\\s+EQU\\s+(\\S+)', 'm'));
    assert.ok(found, name + ' is not EQU\'d in special.s any more');
    const said = found[1];
    if (/^\d+$/.test(said)) return Number(said);
    const label = generated.match(
      new RegExp('^' + said + '\\s+EQU\\s+(\\d+)', 'm'));
    assert.ok(label, name + ' is ' + said + ', which graphics_gen.s does not ' +
              'define -- run build.py to regenerate it');
    return Number(label[1]);
  };
  assert.strictEqual(m.ROWS, equ('SPECIAL_ROWS'));
  assert.strictEqual(m.WANTED, equ('SPECIAL_WANTED'));
  assert.strictEqual(m.FIRST_GRAPHIC, equ('SPECIAL_FIRST'));
  assert.strictEqual(m.LIFE_GRAPHIC, equ('SPECIAL_LIFE'));
  assert.strictEqual(m.SLOTS, equ('SPECIAL_SLOTS'));
  assert.strictEqual(m.SIZE_UV, equ('SPECIAL_SIZE_UV'));
  assert.strictEqual(m.SIZE_Z, equ('SPECIAL_SIZE_Z'));
});

test('a piece is the box special_fill actually sets', () => {
  const piece = m.pieceFor({ index: 3, u: 100, v: 120, z: 64 }, 0, null);
  assert.strictEqual(piece.sizeU, m.SIZE_UV);
  assert.strictEqual(piece.sizeV, m.SIZE_UV);
  assert.strictEqual(piece.sizeZ, m.SIZE_Z);
  assert.strictEqual(piece.u, 100);
  assert.strictEqual(piece.graphic, m.FIRST_GRAPHIC);
  assert.strictEqual(piece.mirrored, false, 'special_fill zeroes the flags');
  assert.strictEqual(piece.background, false, 'it is sorted, not scenery');
  assert.strictEqual(piece.collectable, 3, 'it knows which row it is');
});

test('the eight kinds are the eight graphics the game deals', () => {
  const kinds = m.kindGraphics();
  assert.strictEqual(kinds.length, m.KINDS);
  assert.strictEqual(kinds[0], m.FIRST_GRAPHIC);
  assert.strictEqual(kinds[m.KINDS - 1], m.LIFE_GRAPHIC,
                     'the last kind is the one that is taken, not carried');
  // special_init does `and 7` then `or SPECIAL_FIRST`, so a kind wraps.
  assert.strictEqual(m.pieceFor({ u: 0, v: 0, z: 0 }, m.KINDS, null).graphic,
                     m.FIRST_GRAPHIC);
  assert.strictEqual(m.pieceFor({ u: 0, v: 0, z: 0 }, -1, null).graphic,
                     m.FIRST_GRAPHIC + m.KINDS - 1);
});

// --- reading --------------------------------------------------------------

test('a room\'s collectables carry the index the table keys them by', () => {
  const said = toy();
  said.collectables[5].room = 9;
  said.collectables[7].room = 9;
  const here = m.inRoom(said, 9);
  assert.deepStrictEqual(here.map((c) => c.index), [5, 7, 9]);
});

test('byRoom only holds the rooms that start one', () => {
  const said = toy();
  const rooms = m.byRoom(said);
  assert.strictEqual(rooms.size, m.ROWS, 'the toy puts one in each');
  assert.deepStrictEqual(rooms.get(3), [3]);
  assert.strictEqual(rooms.has(99), false);
});

// --- the slot limit -------------------------------------------------------

test('a third collectable in one room is reported, because it is never placed', () => {
  const said = toy();
  said.collectables[1].room = 0;
  said.collectables[2].room = 0;          // three now start in room 0
  const problems = m.checkSpecials(said, null);
  const slot = problems.filter((p) => /only 2 slots/.test(p));
  assert.strictEqual(slot.length, 1, problems.join(' | '));
  assert.ok(/starts 3 collectables/.test(slot[0]), slot[0]);
  assert.ok(/0, 1, 2/.test(slot[0]), 'it should name which rows: ' + slot[0]);
});

test('two in a room is fine -- that is what the slots are for', () => {
  const said = toy();
  said.collectables[1].room = 0;
  assert.deepStrictEqual(
    m.checkSpecials(said, null).filter((p) => /slots/.test(p)), []);
});

test('a collectable in a room the castle has not got is reported', () => {
  const said = toy();
  const atlas = { rooms: [{ number: 0 }, { number: 1 }] };
  const problems = m.checkSpecials(said, atlas);
  assert.ok(problems.some((p) => /the castle does not have/.test(p)));
  // ...and with no castle to check against, nothing is claimed.
  assert.deepStrictEqual(
    m.checkSpecials(said, null).filter((p) => /castle/.test(p)), []);
});

test('a short table and a bad kind are both reported', () => {
  const short = toy();
  short.collectables.pop();
  assert.ok(m.checkSpecials(short, null).some((p) => /not 32/.test(p)));

  const bad = toy();
  bad.wanted[0] = 9;
  assert.ok(m.checkSpecials(bad, null).some((p) => /a kind is 0 to 7/.test(p)));

  const stubby = toy();
  stubby.wanted.pop();
  assert.ok(m.checkSpecials(stubby, null).some((p) => /not 14/.test(p)));
});

// --- editing --------------------------------------------------------------

test('moving one leaves the original alone', () => {
  const said = toy();
  const before = JSON.stringify(said);
  const after = m.moveCollectable(said, 4, { u: 100, room: 7 });
  assert.strictEqual(JSON.stringify(said), before, 'the input was mutated');
  assert.strictEqual(after.collectables[4].u, 100);
  assert.strictEqual(after.collectables[4].room, 7);
  assert.strictEqual(after.collectables[4].v, 128, 'what was not named stays');
});

test('a coordinate is clamped to a byte, because the game\'s is one', () => {
  const after = m.moveCollectable(toy(), 0, { u: 300, v: -5, z: 12.6 });
  assert.strictEqual(after.collectables[0].u, 255);
  assert.strictEqual(after.collectables[0].v, 0);
  assert.strictEqual(after.collectables[0].z, 13);
});

test('moving a row that is not there changes nothing', () => {
  const said = toy();
  const after = m.moveCollectable(said, 99, { u: 1 });
  assert.deepStrictEqual(after.collectables, said.collectables);
});

test('the wizard\'s list takes a kind and clamps it', () => {
  const after = m.setWanted(toy(), 2, 5);
  assert.strictEqual(after.wanted[2], 5);
  assert.strictEqual(m.setWanted(toy(), 0, 99).wanted[0], m.KINDS - 1);
  assert.deepStrictEqual(m.setWanted(toy(), 99, 1).wanted, toy().wanted);
});

test('serializing keeps the file\'s own line endings', () => {
  const unix = m.serializeSpecials(toy(), '\n');
  const dos = m.serializeSpecials(toy(), '\r\n');
  assert.strictEqual(dos.replace(/\r\n/g, '\n'), unix);
  assert.ok(unix.endsWith('\n'));
});

// --- the real file --------------------------------------------------------

test('the real specials.json round-trips through parse and serialize', () => {
  const file = path.join(KNIGHTLORE, 'specials.json');
  if (!fs.existsSync(file)) skip('knightlore/specials.json is not here');
  const text = fs.readFileSync(file, 'utf8');
  const eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
  assert.strictEqual(m.serializeSpecials(m.parseSpecials(text), eol), text);
});

test('the real specials.json has nothing wrong with it', () => {
  const said = realSpecials();
  const roomsFile = path.join(KNIGHTLORE, 'rooms.json');
  const atlas = fs.existsSync(roomsFile)
    ? JSON.parse(fs.readFileSync(roomsFile, 'utf8')) : null;
  assert.deepStrictEqual(m.checkSpecials(said, atlas), []);
});

test('the real game puts at most two collectables in any room', () => {
  // Not a rule anyone wrote down -- it is what Ultimate's own table happens to
  // do, and it has to, because the game would silently drop the third.
  const rooms = m.byRoom(realSpecials());
  const crowded = Array.from(rooms.entries()).filter(([, r]) => r.length > m.SLOTS);
  assert.deepStrictEqual(crowded, []);
  const sums = m.summary(realSpecials());
  assert.strictEqual(sums.rows, m.ROWS);
  assert.strictEqual(sums.wanted, m.WANTED);
  assert.strictEqual(sums.crowded, 0);
});

test('every collectable starts in a room the castle has', () => {
  const roomsFile = path.join(KNIGHTLORE, 'rooms.json');
  if (!fs.existsSync(roomsFile)) skip('knightlore/rooms.json is not here');
  const atlas = JSON.parse(fs.readFileSync(roomsFile, 'utf8'));
  const have = new Set(atlas.rooms.map((r) => r.number));
  for (const entry of m.collectablesOf(realSpecials())) {
    assert.ok(have.has(entry.room),
              'room $' + entry.room.toString(16) + ' is not in the castle');
  }
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
