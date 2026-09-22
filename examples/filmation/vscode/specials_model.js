// Knight Lore's collectables: what specials.json says, and the edits you can
// make to it.
//
// The thirty-two objects the wizard sends you for. specials.json holds where
// each one lies when a game starts and the order he asks for them in;
// specials_source.py turns it into specials_gen.s, which knightlore.s
// INCLUDEs. It is the one part of a room that is not in rooms.json, which is
// why the designer has to open a second file to show it.
//
// Three things about them are the game's, not the designer's, and all three
// are why this is a model rather than a form over four numbers:
//
//   * A collectable has no fixed KIND. special_init deals the graphics out at
//     the start of every game, counting on from a random number, so no two
//     games put the same object in the same place. The designer can only show
//     a representative one.
//   * A room has TWO slots. special_room_enter fills the next two records
//     after everything the room data made and stops; a third collectable
//     naming the same room is simply never placed. Nothing warns you, and the
//     object is unreachable for that game.
//   * The table is a fixed thirty-two rows, because special_init copies it in
//     one LDIR.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node examples/filmation/vscode/tests/specials_model_test.js). The page gets it
// inlined as source, which is why nothing here may use require() and why the
// export at the bottom is guarded.

'use strict';

// The game's own constants, from knightlore/special.s. Named here rather than
// written into the code below, because when one of them changes in the game it
// has to change here too and a search for the name is how that is found.
const ROWS = 32;                // SPECIAL_ROWS: the table's fixed length
const WANTED = 14;              // SPECIAL_WANTED: how many the wizard asks for
const KINDS = 8;                // how many kinds there are, and so 0 to 7
const FIRST_GRAPHIC = 96;       // SPECIAL_FIRST: the first collectable graphic
const LIFE_GRAPHIC = 103;       // SPECIAL_LIFE: the one taken rather than carried
const SLOTS = 2;                // SPECIAL_SLOTS: how many a room can show
const SIZE_UV = 5;              // SPECIAL_SIZE_UV: the game's box, all of them
const SIZE_Z = 12;              // SPECIAL_SIZE_Z

function parseSpecials(text) {
  return JSON.parse(text);
}

function serializeSpecials(said, eol) {
  const text = JSON.stringify(said, null, 1) + '\n';
  return eol === '\r\n' ? text.replace(/\n/g, '\r\n') : text;
}

function collectablesOf(said) {
  return (said && said.collectables) || [];
}

function wantedOf(said) {
  return (said && said.wanted) || [];
}

// The rows that start in one room, with the index each one is in the table --
// the index matters, because it is what the wanted list and special_gfx are
// keyed by, and what an edit names.
function inRoom(said, room) {
  const out = [];
  const list = collectablesOf(said);
  for (let i = 0; i < list.length; i++) {
    if (list[i] && list[i].room === room) out.push({ index: i, ...list[i] });
  }
  return out;
}

// room number -> how many rows start there, for the map and for the check
// below. Only rooms with at least one are in it.
function byRoom(said) {
  const out = new Map();
  const list = collectablesOf(said);
  for (let i = 0; i < list.length; i++) {
    const room = list[i] && list[i].room;
    if (room === undefined || room === null) continue;
    if (!out.has(room)) out.set(room, []);
    out.get(room).push(i);
  }
  return out;
}

// --- drawing --------------------------------------------------------------

// A collectable as a piece room_render.js can place and sort.
//
// The graphic is a stand-in: the game deals kinds at random, so there is no
// right answer and this takes the first, or whichever kind the caller is
// cycling through. Everything else is what special_fill actually sets -- the
// box is SPECIAL_SIZE_UV square by SPECIAL_SIZE_Z, the same for all of them,
// and the flags are zeroed -- so the piece sorts against the room's own
// furniture exactly as it will in the game.
function pieceFor(entry, kind, graphicName) {
  const offset = ((kind || 0) % KINDS + KINDS) % KINDS;
  return {
    graphic: FIRST_GRAPHIC + offset,
    graphicName: graphicName || null,
    u: entry.u,
    v: entry.v,
    z: entry.z,
    sizeU: SIZE_UV,
    sizeV: SIZE_UV,
    sizeZ: SIZE_Z,
    mirrored: false,
    background: false,
    collectable: entry.index
  };
}

// The eight graphic numbers a collectable can be dealt, for a picker.
function kindGraphics() {
  const out = [];
  for (let i = 0; i < KINDS; i++) out.push(FIRST_GRAPHIC + i);
  return out;
}

// --- editing --------------------------------------------------------------

// Move one collectable, or send it to another room. A copy rather than a
// change in place: the host writes whole documents and lets the editor's undo
// do the rest, so nothing here may mutate what it was given.
//
// The fields are clamped to a byte because the game's are bytes: a U of 300
// would be written as 44 by specials_source.py and the designer would have
// shown something the game will not.
function moveCollectable(said, index, patch) {
  const next = JSON.parse(JSON.stringify(said));
  const list = next.collectables || (next.collectables = []);
  const entry = list[index];
  if (!entry) return next;
  for (const key of ['room', 'u', 'v', 'z']) {
    if (patch[key] === undefined) continue;
    entry[key] = Math.max(0, Math.min(255, Math.round(patch[key])));
  }
  return next;
}

// Reorder the wizard's list. The values are kinds, 0 to 7, and repeats are
// ordinary -- he asks for some kinds more than once.
function setWanted(said, at, kind) {
  const next = JSON.parse(JSON.stringify(said));
  const list = next.wanted || (next.wanted = []);
  if (at < 0 || at >= list.length) return next;
  list[at] = Math.max(0, Math.min(KINDS - 1, Math.round(kind)));
  return next;
}

// --- checking -------------------------------------------------------------

// What would go wrong in a game, for the page to show rather than stop on.
//
// `atlas` is the castle, when there is one: a collectable in a room the castle
// does not have is unreachable, and that is worth saying. Without it the room
// numbers are not checked.
function checkSpecials(said, atlas) {
  const problems = [];
  const list = collectablesOf(said);

  if (list.length !== ROWS) {
    problems.push('There are ' + list.length + ' collectables, not ' + ROWS +
                  '. special_init copies the table in one LDIR, so it is a ' +
                  'fixed ' + ROWS + ' rows and the build will stop.');
  }

  const wanted = wantedOf(said);
  if (wanted.length !== WANTED) {
    problems.push('The wizard asks for ' + wanted.length + ', not ' + WANTED +
                  '. SPECIAL_WANTED in the game is ' + WANTED + ', and he would ' +
                  'read off the end of his own list.');
  }
  for (let i = 0; i < wanted.length; i++) {
    if (!Number.isInteger(wanted[i]) || wanted[i] < 0 || wanted[i] >= KINDS) {
      problems.push('The wizard’s ' + (i + 1) + 'th is ' + wanted[i] +
                    '; a kind is 0 to ' + (KINDS - 1) + '.');
    }
  }

  // The one that actually loses you an object, and the one nothing warns about
  // in the game: a room shows SPECIAL_SLOTS of them and no more.
  for (const [room, rows] of byRoom(said)) {
    if (rows.length > SLOTS) {
      problems.push('Room $' + room.toString(16).toUpperCase().padStart(2, '0') +
                    ' starts ' + rows.length + ' collectables (' + rows.join(', ') +
                    ') but a room has only ' + SLOTS + ' slots, so the rest are ' +
                    'never placed.');
    }
  }

  if (atlas && atlas.rooms) {
    const have = new Set(atlas.rooms.map((r) => r.number));
    for (let i = 0; i < list.length; i++) {
      const room = list[i] && list[i].room;
      if (room !== undefined && !have.has(room)) {
        problems.push('Collectable ' + i + ' starts in room $' +
                      room.toString(16).toUpperCase().padStart(2, '0') +
                      ', which the castle does not have.');
      }
    }
  }

  return problems;
}

function summary(said) {
  const rooms = byRoom(said);
  let crowded = 0;
  for (const rows of rooms.values()) if (rows.length > SLOTS) crowded++;
  return {
    rows: collectablesOf(said).length,
    rooms: rooms.size,
    wanted: wantedOf(said).length,
    crowded: crowded
  };
}

if (typeof module !== 'undefined') {
  module.exports = {
    ROWS, WANTED, KINDS, FIRST_GRAPHIC, LIFE_GRAPHIC, SLOTS, SIZE_UV, SIZE_Z,
    parseSpecials, serializeSpecials, collectablesOf, wantedOf,
    inRoom, byRoom, pieceFor, kindGraphics,
    moveCollectable, setWanted, checkSpecials, summary
  };
}
