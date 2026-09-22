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
const sheetModel = require('../sheet_model');

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

// A castle is two files: the rooms, and the templates they place. Both
// editors work on the two merged, and so do these tests.
function atlasFor(game) {
  return m.withTemplates(m.parseAtlas(textFor(game)), m.parseTemplates(templatesText(game)));
}

function templatesText(game) {
  const file = path.join(FILMATION, game, 'templates.json');
  if (!fs.existsSync(file)) skip(game + '/templates.json is not here');
  return fs.readFileSync(file, 'utf8');
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

function graphicsFor(game) {
  const file = path.join(FILMATION, game, 'graphics.json');
  if (!fs.existsSync(file)) skip(game + '/graphics.json is not here');
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
// ...and templates.json, the same way.
for (const game of GAMES) {
  test(game + ': writing the templates back gives the same bytes', function () {
    const text = templatesText(game);
    const atlas = m.withTemplates(m.parseAtlas(textFor(game)), m.parseTemplates(text));
    assert.strictEqual(m.serializeTemplates(atlas, m.eolOf(text)), text);
  });
}

for (const game of GAMES) {
  test(game + ': writing it back gives the same bytes', function () {
    const text = textFor(game);
    const again = m.serializeAtlas(atlasFor(game), m.eolOf(text));
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
    roomDimensions: { square: { u: 64, v: 64, z: floorZ } },
    sceneryTemplates: {},
    objectTemplates: { object_test: [entry] },
    rooms: []
  };
  const room = { number: 0, ink: 0, dimensions: 'square',
    scenery: [], objects: [
    { template: 'object_test', positions: [position] }
  ] };
  return m.expandRoom(atlas, room, TEST_NUMBERS, TEST_BOXES)[0];
}

// The entry below states a box of its own, which is the override an entry may
// carry -- so these tests need no graphics.json behind them. An empty map is
// what "the graphic says nothing" looks like.
const TEST_BOXES = new Map();

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
    const first = m.expandRoom(atlas, rooms[0], m.graphicNumbers(sheetFor(game), graphicsFor(game)))
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
    for (const name of Object.keys(atlas.sceneryTemplates)) {
      const pieces = atlas.sceneryTemplates[name];
      // rooms_source.py labels them bg_ (Knight Lore) or scn_ (Pentagram).
      const stem = name.replace(/^scenery_/, '');
      const rows = blocks.get('bg_' + stem) || blocks.get('scn_' + stem) ||
                   blocks.get(name);
      if (!rows) continue;                  // a shared template, emitted once
      const wanted = m.isBackgroundTemplate(game, name);
      for (let i = 0; i < rows.length && i < pieces.length; i++) {
        const flags = rows[i][rows[i].length - 1];
        assert.strictEqual(!!(flags & BACKGROUND_FLAG), wanted,
          name + ' piece ' + i + ': background');
        assert.strictEqual(!!(flags & FLIP_FLAG), pieces[i].flags.mirrored,
          name + ' piece ' + i + ': flip');
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
  return atlasFor('knightlore');
}

test('addObject: fills a group of the same template before starting another',
  function () {
    // A group holds one template and up to eight positions, because the repeat
    // count is the bottom three bits of the group byte.
    const room = { number: 0, ink: 0, dimensions: 'square',
      scenery: [], objects: [] };
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
    const template = atlas.sceneryTemplates.scenery_arch_n;
    const was = template[0].flags.mirrored;

    m.setTemplateField(template, 'blocks', 0, 'flags.mirrored', !was);
    assert.strictEqual(template[0].flags.mirrored, !was);
    m.setTemplateField(template, 'blocks', 0, 'u', 9);
    assert.strictEqual(template[0].u, 9);

    // The raise is added into Z and masked with $FC, so it only ever holds
    // multiples of four however it is asked for.
    const object = atlas.objectTemplates.object_block;
    m.setTemplateField(object, 'entries', 0, 'offsets.raiseZ', 50);
    assert.strictEqual(object[0].offsets.raiseZ, 48);

    assert.strictEqual(m.setTemplateField(template, 'blocks', 0, 'nonsense', 1), null);
    assert.strictEqual(m.setTemplateField(template, 'blocks', 0, 'flags.nope', 1), null);
    assert.strictEqual(m.setTemplateField(template, 'blocks', 9, 'u', 1), null);

    // The box belongs to the GRAPHIC and lives in graphics.json, so it is not
    // a field of the entry any more -- asking to set one here would quietly
    // give this template an override of its own.
    assert.strictEqual(m.setTemplateField(template, 'blocks', 0, 'sizeU', 9), null);
    assert.strictEqual(template[0].sizeU, undefined);
    assert.strictEqual(
      m.setTemplateField(atlas.objectTemplates.object_block, 'entries', 0,
                         'sizeZ', 9), null);
  });

test('setTemplateGraphic: only a name the table has a number for', function () {
  const atlas = knightLoreAtlas();
  const template = atlas.objectTemplates.object_block;
  const numbers = m.graphicNumbers(sheetFor('knightlore'), graphicsFor('knightlore'));
  const names = Array.from(numbers.keys());

  assert.ok(m.setTemplateGraphic(numbers, template, 'entries', 0, names[3]));
  assert.strictEqual(template[0].graphic, names[3]);
  // A graphic with no number cannot be built, so it is refused rather than
  // written and discovered at the next build.
  assert.strictEqual(
    m.setTemplateGraphic(numbers, template, 'entries', 0, 'no_such_graphic'), null);
  assert.strictEqual(template[0].graphic, names[3], 'left alone');
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
  // Worked out from the rooms rather than read off a flag in the file: a
  // template is its pieces now, and `used` was only something to fall out of
  // date with the rest of the castle.
  const named = m.refreshUsage(atlas);
  const unused = Object.keys(atlas.objectTemplates).filter(function (name) {
    return !named.has(name);
  });
  // Two are in the game and never placed: a fire standing still, and the
  // spikes raised on something. rooms_source.py leaves both out.
  assert.strictEqual(unused.length, 2, unused.join(', '));
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

// --- the templates panel's operations --------------------------------------

test('doorways are decided by position, not by name', function () {
  // Knight Lore's room_build.s tests the index, so renaming an arch must not
  // stop the designer seeing a doorway the game still sees.
  const atlas = knightLoreAtlas();
  assert.strictEqual(m.doorwayOf(atlas, 'scenery_arch_e'), 'e');
  m.renameTemplate(atlas, 'scenery_arch_e', 'east_way_out');
  assert.strictEqual(m.doorwayOf(atlas, 'east_way_out'), 'e');
  assert.strictEqual(m.doorwayOf(atlas, 'scenery_high_arch_e'), 'e');
  assert.strictEqual(m.doorwayOf(atlas, 'scenery_high_arch_e_base'), null);
  assert.strictEqual(m.doorwayOf(atlas, 'scenery_walls_0'), null);
});

test('a rename keeps the template where it is in the table', function () {
  // The position is the game's own number for it.
  const atlas = knightLoreAtlas();
  const before = Object.keys(atlas.objectTemplates);
  const at = before.indexOf('object_guard_ew');
  assert.ok(m.renameTemplate(atlas, 'object_guard_ew', 'object_sentry') > 0);
  assert.strictEqual(Object.keys(atlas.objectTemplates)[at], 'object_sentry');
  assert.strictEqual(Object.keys(atlas.objectTemplates).length, before.length);
});

test('a template name has to be able to be a label', function () {
  const atlas = knightLoreAtlas();
  assert.ok(m.templateNameProblem(atlas, 'Has Spaces'));
  assert.ok(m.templateNameProblem(atlas, '9lives'));
  assert.ok(m.templateNameProblem(atlas, 'scenery_arch_n'), 'taken');
  assert.ok(m.templateNameProblem(atlas, 'object_block'), 'taken in the other table');
  assert.strictEqual(m.templateNameProblem(atlas, 'object_new_thing'), null);
  assert.strictEqual(m.renameTemplate(atlas, 'object_block', 'Bad Name'), null);
});

test('a new template goes on the end of its table', function () {
  const atlas = knightLoreAtlas();
  const count = Object.keys(atlas.objectTemplates).length;
  assert.strictEqual(m.newTemplate(atlas, 'objectTemplates', 'object_new'), count);
  assert.deepStrictEqual(atlas.objectTemplates.object_new, []);
  assert.strictEqual(Object.keys(atlas.objectTemplates)[count], 'object_new');
});

test('the object table stops at 32', function () {
  // Five bits of a room's group byte.
  const atlas = knightLoreAtlas();
  let made = 0;
  while (m.newTemplate(atlas, 'objectTemplates', 'object_extra_' + made) !== null) {
    made++;
  }
  assert.strictEqual(Object.keys(atlas.objectTemplates).length, 32);
});

test('a duplicate is a copy of the pieces, on the end', function () {
  const atlas = knightLoreAtlas();
  const at = m.duplicateTemplate(atlas, 'sceneryTemplates', 'scenery_arch_n', 'my_arch');
  assert.strictEqual(at, Object.keys(atlas.sceneryTemplates).length - 1);
  assert.deepStrictEqual(atlas.sceneryTemplates.my_arch, atlas.sceneryTemplates.scenery_arch_n);
  atlas.sceneryTemplates.my_arch[0].u = 1;
  assert.notStrictEqual(atlas.sceneryTemplates.scenery_arch_n[0].u, 1, 'not shared');
  // ...and it is not a doorway, however much it looks like one: the game
  // decides that by position, and this one is past the arches.
  assert.strictEqual(m.doorwayOf(atlas, 'my_arch'), null);
});

test('only an unused template on the end of its table can be deleted', function () {
  const atlas = knightLoreAtlas();
  // In use.
  assert.ok(/places it/.test(m.deleteProblem(atlas, 'sceneryTemplates', 'scenery_arch_n')));
  // Unused, but not last: two object templates no room places sit mid-table.
  const unused = Object.keys(atlas.objectTemplates).filter(function (name) {
    return !m.refreshUsage(atlas).has(name);
  });
  assert.ok(unused.length);
  const last = Object.keys(atlas.objectTemplates).slice(-1)[0];
  for (const name of unused) {
    if (name !== last) {
      assert.ok(/renumber/.test(m.deleteProblem(atlas, 'objectTemplates', name)), name);
    }
  }
  // Made here, unused, last: it can go, and nothing moves.
  const before = Object.keys(atlas.objectTemplates);
  m.newTemplate(atlas, 'objectTemplates', 'object_scratch');
  assert.strictEqual(m.deleteProblem(atlas, 'objectTemplates', 'object_scratch'), null);
  assert.ok(m.deleteTemplate(atlas, 'objectTemplates', 'object_scratch'));
  assert.deepStrictEqual(Object.keys(atlas.objectTemplates), before);
});

test('pieces can be added, moved and removed', function () {
  const atlas = knightLoreAtlas();
  m.newTemplate(atlas, 'sceneryTemplates', 'my_wall');
  const wall = atlas.sceneryTemplates.my_wall;
  assert.strictEqual(m.addPiece(wall, 'sceneryTemplates', 'scenery.block.g7'), 0);
  assert.strictEqual(m.addPiece(wall, 'sceneryTemplates', 'door.castle.1'), 1);
  assert.deepStrictEqual(Object.keys(wall[0]).sort(), ['flags', 'graphic', 'u', 'v', 'z']);
  assert.ok(m.movePiece(wall, 1, 0));
  assert.strictEqual(wall[0].graphic, 'door.castle.1');
  assert.ok(m.removePiece(wall, 0));
  assert.deepStrictEqual(wall.map(function (p) { return p.graphic; }), ['scenery.block.g7']);
  assert.strictEqual(m.removePiece(wall, 5), false);
  assert.strictEqual(m.movePiece(wall, 0, 3), false);

  // An object piece has a nudge instead of a place.
  m.newTemplate(atlas, 'objectTemplates', 'object_mine');
  m.addPiece(atlas.objectTemplates.object_mine, 'objectTemplates', 'scenery.block.g7');
  assert.deepStrictEqual(Object.keys(atlas.objectTemplates.object_mine[0]).sort(),
                         ['flags', 'graphic', 'offsets']);
});

test('the rooms a template is used in, in order', function () {
  const atlas = knightLoreAtlas();
  const rooms = m.roomsUsing(atlas, 'scenery_arch_n');
  assert.ok(rooms.length > 5);
  assert.strictEqual(rooms[0], 0);
  assert.deepStrictEqual(rooms, rooms.slice().sort(function (a, b) { return a - b; }));
  assert.deepStrictEqual(m.roomsUsing(atlas, 'no_such_template'), []);
});

test('a scenery piece moves anywhere its three bytes reach', function () {
  const atlas = knightLoreAtlas();
  const arch = atlas.sceneryTemplates.scenery_arch_n;
  const was = { u: arch[0].u, v: arch[0].v, z: arch[0].z };
  assert.ok(m.shiftPiece(arch, 'sceneryTemplates', 0, { u: 3, v: -2, z: 8 }));
  assert.deepStrictEqual({ u: arch[0].u, v: arch[0].v, z: arch[0].z },
                         { u: was.u + 3, v: was.v - 2, z: was.z + 8 });
  // ...and no further: a byte.
  m.shiftPiece(arch, 'sceneryTemplates', 0, { u: 1000, v: -1000 });
  assert.strictEqual(arch[0].u, 255);
  assert.strictEqual(arch[0].v, 0);
  assert.strictEqual(m.shiftPiece(arch, 'sceneryTemplates', 9, { u: 1 }), false);
});

test('an object piece moves only by its nudge', function () {
  // It takes its place from the room; all it has of its own is half a cell
  // along U and V, and a raise the game masks to a multiple of four.
  const atlas = knightLoreAtlas();
  m.newTemplate(atlas, 'objectTemplates', 'object_mine');
  const mine = atlas.objectTemplates.object_mine;
  m.addPiece(mine, 'objectTemplates', 'scenery.block.g7');

  assert.ok(m.shiftPiece(mine, 'objectTemplates', 0, { u: 8 }));
  assert.strictEqual(mine[0].offsets.halfU, true);
  assert.strictEqual(mine[0].offsets.halfV, false);
  m.shiftPiece(mine, 'objectTemplates', 0, { u: -8, v: 8 });
  assert.strictEqual(mine[0].offsets.halfU, false);
  assert.strictEqual(mine[0].offsets.halfV, true);

  m.shiftPiece(mine, 'objectTemplates', 0, { z: 4 });
  m.shiftPiece(mine, 'objectTemplates', 0, { z: 4 });
  assert.strictEqual(mine[0].offsets.raiseZ, 8);
  m.shiftPiece(mine, 'objectTemplates', 0, { z: 3 });
  assert.strictEqual(mine[0].offsets.raiseZ % 4, 0, 'kept to a multiple of four');
  m.shiftPiece(mine, 'objectTemplates', 0, { z: -1000 });
  assert.strictEqual(mine[0].offsets.raiseZ, 0);
});

test('a drag measures from where the piece was picked up', function () {
  const atlas = knightLoreAtlas();
  const arch = atlas.sceneryTemplates.scenery_arch_n;
  const from = JSON.parse(JSON.stringify(arch[0]));
  // Three moves of a drag, each the total so far, land where the last says --
  // not at the sum of all three.
  m.shiftPiece(arch, 'sceneryTemplates', 0, { u: 2 }, from);
  m.shiftPiece(arch, 'sceneryTemplates', 0, { u: 4 }, from);
  m.shiftPiece(arch, 'sceneryTemplates', 0, { u: 5 }, from);
  assert.strictEqual(arch[0].u, from.u + 5);
});

test('a drag lands the piece under the pointer', function () {
  // Checked through the renderer's own projection, so the inverse is held to
  // what is actually drawn rather than to its own algebra. Across is exact;
  // down is to the nearest two world units, because the projection halves
  // V - U, so it may land one pixel short and never more.
  const render = require('../room_render');
  for (const at of [{ u: 120, v: 130, z: 128 }, { u: 121, v: 130, z: 128 }]) {
    const a = render.project(at, null);
    for (let dx = -9; dx <= 9; dx++) {
      for (let dy = -7; dy <= 7; dy++) {
        const move = m.screenToWorld(dx, dy);
        assert.ok(Number.isInteger(move.u) && Number.isInteger(move.v));
        const b = render.project({ u: at.u + move.u, v: at.v + move.v, z: at.z }, null);
        assert.strictEqual(b.x - a.x, dx, 'across, ' + dx + ',' + dy);
        assert.ok(Math.abs((b.y - a.y) - dy) <= 1, 'down, ' + dx + ',' + dy);
      }
    }
  }
});

test('a world move the screen can show comes back exactly', function () {
  const render = require('../room_render');
  const at = { u: 120, v: 130, z: 128 };
  for (const [du, dv] of [[4, 0], [0, 4], [6, -6], [-10, 2], [16, 16], [3, 5]]) {
    const a = render.project(at, null);
    const b = render.project({ u: at.u + du, v: at.v + dv, z: at.z }, null);
    assert.deepStrictEqual(m.screenToWorld(b.x - a.x, b.y - a.y), { u: du, v: dv },
                           'moved ' + du + ',' + dv);
  }
});

test('the two files have to name each other, and nothing is assumed', function () {
  const rooms = { meta: { templates: 'templates.json' } };
  const templates = { meta: { rooms: 'rooms.json' } };
  assert.strictEqual(m.pairProblem('rooms.json', rooms, 'templates.json', templates), null);

  // Neither name is supplied when a file leaves it out.
  assert.strictEqual(m.templatesFileOf({ meta: {} }), null);
  assert.strictEqual(m.roomsFileOf({ meta: {} }), null);
  assert.ok(/meta\.templates/.test(
    m.pairProblem('rooms.json', { meta: {} }, 'templates.json', templates)));
  assert.ok(/meta\.rooms/.test(
    m.pairProblem('rooms.json', rooms, 'templates.json', { meta: {} })));

  // Two castles' files paired by mistake.
  assert.ok(/not templates\.json/.test(m.pairProblem(
    'rooms.json', { meta: { templates: 'other.json' } }, 'templates.json', templates)));
  assert.ok(/belongs to other_rooms\.json/.test(m.pairProblem(
    'rooms.json', rooms, 'templates.json', { meta: { rooms: 'other_rooms.json' } })));
});

for (const game of GAMES) {
  test(game + ': the shipped pair names each other', function () {
    const rooms = m.parseAtlas(textFor(game));
    const templates = m.parseTemplates(templatesText(game));
    assert.strictEqual(m.pairProblem('rooms.json', rooms, 'templates.json', templates), null);
  });
}

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
      const graphics = graphicsFor(game);
      const mine = m.graphicNames(sheet, graphics);
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

// --- ...and so do the two box rules ----------------------------------------

// The box a template entry occupies is worked out twice as well:
// examples/filmation/graphics.py does it for the build, room_model.js for the
// designer. Both read graphics.json, both swap U and V for a mirrored piece,
// and both let an entry override with one of its own. A disagreement would
// draw a room whose pieces sort and collide differently from the built game's,
// which is exactly the kind of thing nobody notices until a wall is walked
// through.
for (const game of GAMES) {
  test(game + ': the designer boxes graphics exactly as graphics.py does',
    function () {
      const atlas = atlasFor(game);
      const boxes = m.graphicBoxes(sheetFor(game), graphicsFor(game));
      const theirs = pythonBoxes(game);
      if (theirs === null) skip('python could not run graphics.py');

      const apart = [];
      let checked = 0;
      for (const key of ['sceneryTemplates', 'objectTemplates']) {
        for (const name of Object.keys(atlas[key])) {
          atlas[key][name].forEach(function (entry, i) {
            const mine = sheetModel.boxOf(boxes, entry);
            const said = theirs[name + '#' + i];
            checked++;
            if (!mine || !said || mine.u !== said[0] || mine.v !== said[1] ||
                mine.z !== said[2]) {
              apart.push(name + ' entry ' + i + ' (' + entry.graphic +
                         '): js ' + JSON.stringify(mine) +
                         ', py ' + JSON.stringify(said));
            }
          });
        }
      }
      assert.deepStrictEqual(apart.slice(0, 8), []);
      assert.ok(checked > 100, 'checked ' + checked + ' entries');
    });
}

// graphics.py's own answer, asked of it directly: every template entry's box,
// keyed by the template it is in and where in it.
function pythonBoxes(game) {
  const here = path.join(FILMATION, game);
  const script =
    'import json, sys; sys.path.insert(0, r"' + FILMATION + '"); ' +
    'import graphics, castle; ' +
    'atlas = json.load(open(r"' + path.join(here, 'rooms.json') + '")); ' +
    'sizes = graphics.sizes(r"' + here + '"); ' +
    'out = {}; ' +
    '[out.__setitem__(t + "#" + str(i), [b["u"], b["v"], b["z"]]) ' +
    ' for _g, t, i, e in castle.placements(atlas) ' +
    ' for b in [graphics.box_of(sizes, e, t)]]; ' +
    'print(json.dumps(out))';
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
