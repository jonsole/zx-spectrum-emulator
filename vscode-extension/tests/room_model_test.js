// Tests for room_model.js -- what a room expands to, where its doorways lead,
// and what would stop it building. Plain Node, no vscode API and no test
// framework:
//
//   node vscode-extension/tests/room_model_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/room_model_test.js)
//
// The arithmetic tests stand on their own: the expected world coordinates are
// worked out from room_unpack in knightlore/room_build.s, not read back out of
// this model. The rest run against the two games' real rooms.json, and the last
// group reads the generated room_data.s back and requires this model to agree
// with what rooms_source.py wrote -- the background flag especially, which is
// decided by template name in Python and has to be decided the same way here or
// the preview sorts a wall the game does not. room_data.s is gitignored and
// only exists after a build, so those skip when it is absent.

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const m = require('../room_model');

const FILMATION = path.join(__dirname, '..', '..', 'examples', 'filmation');
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

function atlasFor(game) {
  const file = path.join(FILMATION, game, 'rooms.json');
  if (!fs.existsSync(file)) skip(game + '/rooms.json is not here');
  return m.parseAtlas(fs.readFileSync(file, 'utf8'));
}

function textFor(game) {
  const file = path.join(FILMATION, game, 'rooms.json');
  if (!fs.existsSync(file)) skip(game + '/rooms.json is not here');
  return fs.readFileSync(file, 'utf8');
}

function sheetFor(game) {
  const file = path.join(FILMATION, game, 'sprites.json');
  if (!fs.existsSync(file)) skip(game + '/sprites.json has not been unpacked');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function sourceFor(game) {
  const file = path.join(FILMATION, game, 'room_data.s');
  if (!fs.existsSync(file)) skip(game + '/room_data.s has not been generated');
  return fs.readFileSync(file, 'utf8');
}

// --- what the file is -----------------------------------------------------

// rooms.py writes the file with json.dumps(atlas, indent=1) and a trailing
// newline, and will rewrite it whenever room_data.bin moves on. If the
// designer wrote a different shape, every save would rewrite the whole file and
// the two generators would fight over it.
for (const game of GAMES) {
  test(game + ': writing it back gives the same bytes', function () {
    const text = textFor(game);
    const again = m.serializeAtlas(m.parseAtlas(text), m.eolOf(text));
    if (again === text) return;
    // Twelve thousand lines is no use in a failure, so say where they part.
    const was = text.split(/\r?\n/);
    const now = again.split(/\r?\n/);
    for (let i = 0; i < Math.max(was.length, now.length); i++) {
      if (was[i] !== now[i]) {
        assert.fail('line ' + (i + 1) + ': wrote ' + JSON.stringify(now[i]) +
                    ', file has ' + JSON.stringify(was[i]));
      }
    }
    assert.fail('same lines, different length: ' + text.length + ' -> ' + again.length);
  });
}

// --- room_unpack ----------------------------------------------------------
//
// The expected numbers come from room_unpack in knightlore/room_build.s: a cell
// is 16 units, cell 0 starts at 72, a Z level is 12, and the nudge byte is
// added into Z before the two nudge bits are masked off again.

// One object template with one entry, placed once, so the arithmetic is all
// that is being looked at. `entry` is the named form rooms.py writes; leave
// `offsets` off it entirely for Pentagram's shape, which has no nudge byte.
const TEST_NUMBERS = new Map([['a_graphic', 7], ['drawn_by_something_else', 1]]);

function unpack(entry, position, floorZ) {
  const atlas = {
    meta: { game: 'knightlore' },
    sizes: [{ index: 0, u: 64, v: 64, z: floorZ }],
    sceneryTemplates: [],
    objectTemplates: [{ index: 0, name: 'object_test', entries: [entry] }],
    rooms: []
  };
  const room = { number: 0, ink: 0, size: 0, scenery: [], objects: [
    { template: 'object_test', positions: [position] }
  ] };
  return m.expandRoom(atlas, room, TEST_NUMBERS)[0];
}

// The entry those tests place, with whatever nudge they are about.
function anEntry(nudge) {
  const entry = {
    graphic: 'a_graphic', sizeU: 8, sizeV: 8, sizeZ: 12,
    flags: { mirrored: false, passable: false, rest: 0 }
  };
  if (nudge) entry.offsets = nudge;
  return entry;
}

test('room_unpack: cell 0,0,0 sits at the near corner of the floor', function () {
  const p = unpack(anEntry({ halfU: false, halfV: false, raiseZ: 0 }),
                   { u: 0, v: 0, z: 0 }, 128);
  assert.strictEqual(p.u, 72);
  assert.strictEqual(p.v, 72);
  assert.strictEqual(p.z, 128);
});

test('room_unpack: cell 7,7,3 sits at the far corner, three levels up', function () {
  const p = unpack(anEntry(), { u: 7, v: 7, z: 3 }, 128);
  assert.strictEqual(p.u, 7 * 16 + 72);
  assert.strictEqual(p.v, 7 * 16 + 72);
  // Three levels of twelve is 36, which survives the $FC mask whole.
  assert.strictEqual(p.z, 128 + 36);
});

test('room_unpack: the middle of the floor is the world centre', function () {
  // Cells 3 and 4 straddle 128, and a half-cell nudge on cell 3 lands on it.
  const plain = unpack(anEntry(), { u: 3, v: 3, z: 0 }, 128);
  assert.strictEqual(plain.u, 120);
  const nudged = unpack(anEntry({ halfU: true, halfV: false, raiseZ: 0 }),
                        { u: 3, v: 3, z: 0 }, 128);
  assert.strictEqual(nudged.u, 128);
  assert.strictEqual(nudged.v, 120, 'halfU nudges U only');
});

test('room_unpack: the nudge byte raises Z and its low bits do not', function () {
  // room_unpack adds the nudge byte into Z whole and masks $FC off again, so
  // the half-cell bits move the piece across the floor without ever touching
  // its height.
  const nudged = unpack(anEntry({ halfU: true, halfV: true, raiseZ: 0 }),
                        { u: 0, v: 0, z: 0 }, 128);
  assert.strictEqual(nudged.u, 80);
  assert.strictEqual(nudged.v, 80);
  assert.strictEqual(nudged.z, 128, 'the half-cell nudges stay out of Z');
  const raised = unpack(anEntry({ halfU: false, halfV: false, raiseZ: 0x14 }),
                        { u: 0, v: 0, z: 0 }, 128);
  assert.strictEqual(raised.z, 128 + 0x14);
});

test('room_unpack: a five-byte entry has no nudge byte', function () {
  // Pentagram's object entries are five bytes and carry no nudge at all, so an
  // entry with no offsets has to read as no nudge rather than throwing.
  const p = unpack(anEntry(), { u: 1, v: 2, z: 1 }, 128);
  assert.strictEqual(p.u, 16 + 72);
  assert.strictEqual(p.v, 32 + 72);
  assert.strictEqual(p.z, 128 + 12);
});

test('expandRoom: an entry whose graphic is below two draws nothing', function () {
  // room_add takes zero as the end of a template and one as "drawn by
  // something else", and steps over both.
  const below = anEntry();
  below.graphic = 'drawn_by_something_else';      // number 1
  assert.strictEqual(unpack(below, { u: 0, v: 0, z: 0 }, 128), undefined);
});

// --- the shipped castles --------------------------------------------------

for (const game of GAMES) {
  test(game + ': the castle as shipped has nothing wrong with it', function () {
    const atlas = atlasFor(game);
    const problems = m.checkAtlas(atlas).filter(function (p) {
      return p.severity === 'error';
    });
    assert.deepStrictEqual(problems, []);
  });

  test(game + ': scenery is in absolute world coordinates', function () {
    const atlas = atlasFor(game);
    // Scenery carries its own U, V and Z and takes nothing from the room, so
    // the same template in two rooms of different shapes lands in the same
    // place. Knight Lore's walls prove it: they are the room's edges.
    const rooms = atlas.rooms.filter(function (r) {
      return r.scenery.length > 0;
    });
    const first = m.expandRoom(atlas, rooms[0], m.graphicNumbers(sheetFor(game)))
      .filter(function (p) { return p.kind === 'scenery'; });
    assert.ok(first.length > 0, 'the first room has scenery');
    for (const piece of first) {
      assert.ok(piece.u >= 0 && piece.u <= 255, 'U in range');
      assert.ok(piece.z >= 0 && piece.z <= 255, 'Z in range');
      assert.strictEqual(piece.cell, undefined, 'scenery has no cell');
    }
  });
}

test('knightlore: every doorway lands on a room that exists', function () {
  // player_exit's arithmetic and the artwork have to agree: whatever room the
  // arithmetic reaches has to be a room, or walking out of one drops the
  // player somewhere the builder cannot build.
  //
  // Whether the room it lands on has a doorway BACK is a different question.
  // All 260 of the castle's do, as knightlore/player.s claims, but rooms.json
  // is an edited file -- a one-way door is a change someone can legitimately
  // make, and it builds and plays -- so it is reported here and warned about
  // in the designer's own checks rather than failing the suite.
  const atlas = atlasFor('knightlore');
  const map = m.roomMap(atlas);
  assert.ok(map.links.length > 200, 'found ' + map.links.length + ' doorways');
  assert.deepStrictEqual(map.links.filter(function (l) { return !l.exists; }), []);

  const missing = m.unreciprocated(map);
  if (missing.length) {
    console.log('     note: ' + missing.length + ' doorway(s) with no way back -- ' +
                missing.map(function (l) {
                  return l.from + ' -> ' + l.to + ' (' + l.side + ')';
                }).join(', '));
  }
});

test('unreciprocated: finds a doorway with nothing facing back', function () {
  // Built by hand rather than taken off a castle, so it says what it means
  // whatever the file on disk happens to hold.
  const both = { links: [{ from: 1, to: 2, side: 'n' }, { from: 2, to: 1, side: 's' }] };
  assert.deepStrictEqual(m.unreciprocated(both), []);
  const oneWay = { links: [{ from: 1, to: 2, side: 'n' }] };
  assert.deepStrictEqual(m.unreciprocated(oneWay).map(function (l) {
    return l.from + '>' + l.to;
  }), ['1>2']);
});

test('knightlore: east and west wrap inside a row', function () {
  // The number is a row and a column, and the floor directions wrap inside
  // their own row rather than carrying into the next one.
  const atlas = { meta: { game: 'knightlore' } };
  assert.strictEqual(m.destinationOf(atlas, { number: 0x2F }, {}, 'e'), 0x20);
  assert.strictEqual(m.destinationOf(atlas, { number: 0x20 }, {}, 'w'), 0x2F);
  assert.strictEqual(m.destinationOf(atlas, { number: 0x2F }, {}, 'n'), 0x3F);
  assert.strictEqual(m.destinationOf(atlas, { number: 0x0F }, {}, 's'), 0xFF);
});

test('pentagram: a doorway leads where its byte says', function () {
  const atlas = atlasFor('pentagram');
  const map = m.roomMap(atlas);
  assert.ok(map.links.length > 200, 'found ' + map.links.length + ' doorways');
  for (const link of map.links) {
    assert.ok(link.exists, 'room ' + link.from + ' leads to ' + link.to +
                           ', which is not a room');
  }
});

// --- holding the model to what Python generated ---------------------------

// Pull the template blocks back out of the generated source: a label, then its
// DB lines, up to the lone zero that ends it. The flags byte is the last on a
// scenery line and the fifth on an object one, which is how both emitters
// write them.
function templatesFromSource(text) {
  const out = new Map();
  let label = null;
  let rows = [];
  for (const raw of text.split(/\r?\n/)) {
    const labelled = raw.match(/^([a-z_0-9]+):/);
    if (labelled) {
      if (label) out.set(label, rows);
      label = labelled[1];
      rows = [];
      continue;
    }
    if (!label) continue;
    const db = raw.match(/^\s+DB\s+(.*?)(?:\s*;.*)?$/);
    if (!db) continue;
    const fields = db[1].split(',').map(function (f) { return f.trim(); });
    if (fields.length === 1) {              // the zero that ends a template
      out.set(label, rows);
      label = null;
      rows = [];
      continue;
    }
    rows.push(fields.map(function (f) {
      return f.startsWith('$') ? parseInt(f.slice(1), 16) : parseInt(f, 10);
    }));
  }
  if (label) out.set(label, rows);
  return out;
}

const BACKGROUND_FLAG = 0x40;   // OBJ_BACKGROUND, as room_data.s emits it
const FLIP_FLAG = 0x01;         // OBJ_FLIP_H

for (const game of GAMES) {
  test(game + ': background and flip agree with the generated room_data.s', function () {
    const atlas = atlasFor(game);
    const blocks = templatesFromSource(sourceFor(game));
    let checked = 0;
    for (const template of atlas.sceneryTemplates) {
      // rooms_source.py labels them bg_ (Knight Lore) or scn_ (Pentagram).
      const stem = template.name.replace(/^scenery_/, '');
      const rows = blocks.get('bg_' + stem) || blocks.get('scn_' + stem) ||
                   blocks.get(template.name);
      if (!rows) continue;                  // a shared template, emitted once
      const wanted = m.isBackgroundTemplate(game, template.name);
      for (let i = 0; i < rows.length && i < template.blocks.length; i++) {
        const flags = rows[i][rows[i].length - 1];
        assert.strictEqual(!!(flags & BACKGROUND_FLAG), wanted,
          template.name + ' piece ' + i + ': background');
        assert.strictEqual(!!(flags & FLIP_FLAG), template.blocks[i].flags.mirrored,
          template.name + ' piece ' + i + ': flip');
        checked++;
      }
    }
    assert.ok(checked > 20, 'checked ' + checked + ' pieces');
  });

  test(game + ': the pool this model sizes is the one Python emitted', function () {
    const atlas = atlasFor(game);
    const source = sourceFor(game);
    const found = source.match(/ROOM_MAX_OBJECTS\s+EQU\s+(\d+)/);
    assert.ok(found, 'room_data.s names ROOM_MAX_OBJECTS');
    assert.strictEqual(m.poolNeeded(atlas).slots, Number(found[1]));
  });

  test(game + ': the room count agrees too', function () {
    const atlas = atlasFor(game);
    const found = sourceFor(game).match(/ROOM_COUNT\s+EQU\s+(\d+)/);
    assert.ok(found, 'room_data.s names ROOM_COUNT');
    assert.strictEqual(atlas.rooms.length, Number(found[1]));
  });
}

// --- changing a room ------------------------------------------------------

function knightLoreAtlas() {
  return m.parseAtlas(textFor('knightlore'));
}

test('addObject: fills a group of the same template before starting another',
  function () {
    // A group holds one template and up to eight positions, because the repeat
    // count is the bottom three bits of the group byte.
    const room = { number: 0, ink: 0, size: 0, scenery: [], objects: [] };
    for (let i = 0; i < m.GROUP_LIMIT; i++) {
      m.addObject(room, 'object_block', { u: i, v: 0, z: 0 });
    }
    assert.strictEqual(room.objects.length, 1);
    assert.strictEqual(room.objects[0].positions.length, m.GROUP_LIMIT);

    const ninth = m.addObject(room, 'object_block', { u: 0, v: 1, z: 0 });
    assert.strictEqual(room.objects.length, 2, 'the ninth starts a new group');
    assert.deepStrictEqual(ninth, { ref: 1, slot: 0 });
  });

test('addObject: a different template always starts its own group', function () {
  const room = { number: 0, ink: 0, size: 0, scenery: [], objects: [] };
  m.addObject(room, 'object_block', { u: 0, v: 0, z: 0 });
  m.addObject(room, 'object_table', { u: 1, v: 0, z: 0 });
  m.addObject(room, 'object_block', { u: 2, v: 0, z: 0 });
  assert.deepStrictEqual(room.objects.map(function (g) { return g.template; }),
                         ['object_block', 'object_table']);
  assert.strictEqual(room.objects[0].positions.length, 2);
});

test('removeObject: an emptied group goes with its last object', function () {
  // An empty group would still cost its own byte and place nothing.
  const room = { number: 0, ink: 0, size: 0, scenery: [], objects: [] };
  m.addObject(room, 'object_block', { u: 0, v: 0, z: 0 });
  m.removeObject(room, 0, 0);
  assert.deepStrictEqual(room.objects, []);
});

test('moveObject and retemplateObject', function () {
  const room = { number: 0, ink: 0, size: 0, scenery: [], objects: [] };
  m.addObject(room, 'object_block', { u: 0, v: 0, z: 0 });
  m.moveObject(room, 0, 0, { u: 5, v: 6, z: 2 });
  assert.deepStrictEqual(room.objects[0].positions[0], { u: 5, v: 6, z: 2 });

  // Changing what an object is drawn from moves it between groups, keeping
  // where it stands.
  m.retemplateObject(room, 0, 0, 'object_chest');
  assert.strictEqual(room.objects.length, 1);
  assert.strictEqual(room.objects[0].template, 'object_chest');
  assert.deepStrictEqual(room.objects[0].positions[0], { u: 5, v: 6, z: 2 });
});

test('renameTemplate: every room that names it follows', function () {
  const atlas = knightLoreAtlas();
  const users = atlas.rooms.filter(function (room) {
    return room.objects.some(function (g) { return g.template === 'object_block'; });
  }).length;
  assert.ok(users > 10, 'plenty of rooms name it');

  const moved = m.renameTemplate(atlas, 'object_block', 'object_cube');
  assert.ok(moved > users, 'the template and all its references');
  assert.strictEqual(m.byName(atlas.objectTemplates).has('object_cube'), true);
  for (const room of atlas.rooms) {
    for (const group of room.objects) {
      assert.notStrictEqual(group.template, 'object_block');
    }
  }
  // And it still checks out, which is what would have broken.
  assert.deepStrictEqual(m.checkAtlas(atlas).filter(function (p) {
    return p.severity === 'error';
  }), []);
});

test('renameTemplate: refuses a name already taken', function () {
  const atlas = knightLoreAtlas();
  assert.strictEqual(m.renameTemplate(atlas, 'object_block', 'object_chest'), null);
  assert.strictEqual(m.renameTemplate(atlas, 'object_nothing', 'object_new'), null);
});

test('setTemplateField: edits a field, and refuses one that is not there',
  function () {
    const atlas = knightLoreAtlas();
    const template = atlas.sceneryTemplates[0];
    const was = template.blocks[0].flags.mirrored;

    m.setTemplateField(template, 'blocks', 0, 'flags.mirrored', !was);
    assert.strictEqual(template.blocks[0].flags.mirrored, !was);
    m.setTemplateField(template, 'blocks', 0, 'sizeU', 9);
    assert.strictEqual(template.blocks[0].sizeU, 9);

    // The raise is added into Z and masked with $FC, so it only ever holds
    // multiples of four however it is asked for.
    const object = atlas.objectTemplates[0];
    m.setTemplateField(object, 'entries', 0, 'offsets.raiseZ', 50);
    assert.strictEqual(object.entries[0].offsets.raiseZ, 48);

    assert.strictEqual(m.setTemplateField(template, 'blocks', 0, 'nonsense', 1), null);
    assert.strictEqual(m.setTemplateField(template, 'blocks', 0, 'flags.nope', 1), null);
    assert.strictEqual(m.setTemplateField(template, 'blocks', 9, 'sizeU', 1), null);
  });

test('setTemplateGraphic: only a name the table has a number for', function () {
  const atlas = knightLoreAtlas();
  const template = atlas.objectTemplates[0];
  const numbers = m.graphicNumbers(sheetFor('knightlore'));
  const names = Array.from(numbers.keys());

  assert.ok(m.setTemplateGraphic(numbers, template, 'entries', 0, names[3]));
  assert.strictEqual(template.entries[0].graphic, names[3]);
  // A graphic with no number cannot be built, so it is refused rather than
  // written and discovered at the next build.
  assert.strictEqual(
    m.setTemplateGraphic(numbers, template, 'entries', 0, 'no_such_graphic'), null);
  assert.strictEqual(template.entries[0].graphic, names[3], 'left alone');
});

test('checkAtlas: catches what the emitters assert', function () {
  const atlas = knightLoreAtlas();
  const room = atlas.rooms[0];

  // More scenery than the count field in the attribute byte can hold.
  const scenery = room.scenery.slice();
  while (room.scenery.length <= 7) m.addScenery(atlas, room, 'scenery_walls_0', 0);
  let problems = m.checkAtlas(atlas);
  assert.ok(problems.some(function (p) { return /count field/.test(p.text); }),
    'too much scenery is caught');
  room.scenery = scenery;

  // A position off the eight-by-eight floor.
  m.addObject(room, 'object_block', { u: 9, v: 0, z: 0 });
  problems = m.checkAtlas(atlas);
  assert.ok(problems.some(function (p) { return /off the grid/.test(p.text); }),
    'an off-grid position is caught');
});

test('refreshUsage: says which templates no room names', function () {
  const atlas = knightLoreAtlas();
  m.refreshUsage(atlas);
  const unused = atlas.objectTemplates.filter(function (t) { return !t.used; });
  // Two are in the game and never placed: a fire standing still, and the
  // spikes raised on something. rooms_source.py leaves both out.
  assert.strictEqual(unused.length, 2, unused.map(function (t) {
    return t.name;
  }).join(', '));
});

// --- the artwork a castle names -------------------------------------------

for (const game of GAMES) {
  test(game + ': names the artwork it is drawn with', function () {
    const atlas = atlasFor(game);
    const named = m.spriteFilesOf(atlas);
    // A template carries a graphic NUMBER, which is the game's own index and
    // means nothing without a sheet numbered the same way. The file says which
    // one rather than leaving whatever opens it to assume.
    assert.deepStrictEqual(named, m.SPRITE_FILES,
      'the shipped castles name the files they always used');
    assert.ok(atlas.meta.sprites, 'and say so in meta, not just by default');
    for (const key of Object.keys(m.SPRITE_FILES)) {
      const file = path.join(FILMATION, game, named[key]);
      // sprites.png and sprites.json are gitignored, so only the nudge table
      // is certain to be here; the others only after a build.
      if (key === 'adjust') assert.ok(fs.existsSync(file), file + ' is missing');
    }
  });
}

test('spriteFilesOf: falls back a key at a time', function () {
  // A rooms.json written before the field existed has no meta.sprites at all,
  // and must keep working.
  assert.deepStrictEqual(m.spriteFilesOf({ meta: {} }), m.SPRITE_FILES);
  assert.deepStrictEqual(m.spriteFilesOf({}), m.SPRITE_FILES);

  const some = m.spriteFilesOf({ meta: { sprites: { sheet: 'other.png' } } });
  assert.strictEqual(some.sheet, 'other.png');
  assert.strictEqual(some.atlas, m.SPRITE_FILES.atlas, 'the rest still default');

  // Anything that is not a usable name is ignored rather than believed.
  const junk = m.spriteFilesOf({ meta: { sprites: { sheet: '', atlas: 7, adjust: null } } });
  assert.deepStrictEqual(junk, m.SPRITE_FILES);
});

// --- the two namers agree --------------------------------------------------

// The names come out of the sprite sheet twice: examples/filmation/graphics.py
// does it for the build, and room_model.js does it for the designer. If they
// ever disagreed, rooms_source.py would put a different number in a record
// from the one the designer drew, and a castle would be built out of the wrong
// pieces without anything saying so.
for (const game of GAMES) {
  test(game + ': the designer names graphics exactly as graphics.py does',
    function () {
      const sheet = sheetFor(game);
      const mine = m.graphicNames(sheet);
      const theirs = pythonNames(game);
      if (theirs === null) skip('python could not run graphics.py');

      const numbers = new Set([...mine.keys(), ...Object.keys(theirs).map(Number)]);
      const apart = [];
      for (const graphic of numbers) {
        if (mine.get(graphic) !== theirs[graphic]) {
          apart.push(graphic + ': js ' + mine.get(graphic) + ', py ' + theirs[graphic]);
        }
      }
      assert.deepStrictEqual(apart, []);
      assert.ok(numbers.size > 100, 'named ' + numbers.size + ' graphics');
    });
}

// graphics.py's own answer, asked of it directly.
function pythonNames(game) {
  const here = path.join(FILMATION, game);
  const script =
    'import json, sys; sys.path.insert(0, r"' + FILMATION + '"); ' +
    'import graphics; ' +
    'print(json.dumps(graphics.names(r"' + here + '")))';
  for (const python of [
    path.join(FILMATION, '..', '..', '.venv-win', 'Scripts', 'python.exe'), 'python'
  ]) {
    const done = childProcess.spawnSync(python, ['-c', script], { encoding: 'utf8' });
    if (done.status === 0 && done.stdout) return JSON.parse(done.stdout);
  }
  return null;
}

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
