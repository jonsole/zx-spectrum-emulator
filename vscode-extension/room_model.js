// The room designer's pure half: what a Filmation castle is, what a room
// expands to, how its rooms join up, and what would stop it building.
//
// The file it works on is examples/filmation/<game>/rooms.json, which is the
// editable form of a game's rooms. rooms.py decodes the game's own tables into
// it and rooms_source.py turns it back into room_data.s, so a change made here
// reaches the build without going anywhere near the original bytes. Both games
// write the same schema; where they differ is written down below rather than
// branched on twice.
//
// A room is not a list of objects. It is an attribute byte and a handful of
// indices naming templates -- pieces of scenery, and groups of objects --
// shared across the whole game, and the engine expands them when the room is
// built. expandRoom does the same expansion here, in world coordinates, so the
// designer shows what room_build.s would make rather than what the JSON looks
// like. room_unpack in the game's room_build.s is what it mirrors, field for
// field; the constants below come from there.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node vscode-extension/tests/room_model_test.js). The page gets it inlined as
// source the way graphics_model.js and tape_model.js are, which is why nothing
// here may use require() and why the export at the bottom is guarded.

'use strict';

// --- the world ------------------------------------------------------------
//
// A room's floor is eight cells square, and a cell is 16 world units. Cell 0
// starts at 72, so the eight cells run 72..184 and their middle is 128, the
// centre every room is measured from. room_unpack adds the 72; the designer
// has to add it too or nothing lands where the game puts it.
const CELL = 16;
const CELL_ORIGIN = 72;
const HALF_CELL = 8;            // what the template's halfU/halfV nudge is worth
const CELLS = 8;                // cells along U and along V
const LEVELS = 4;               // Z levels a packed position can name

// A Z level is 12 units, and the template's own nudge is added before the two
// nudge bits are masked off again -- room_unpack does `add a,c` then `and $FC`,
// which works because level * 12 is always a multiple of four. Doing it in two
// steps here would put a half-cell nudge into the height.
const LEVEL_Z = 12;
const Z_MASK = 0xFC;

// room_add ignores an entry whose graphic is below two: zero ends a template
// and one means "drawn by something else". They still occupy an entry, so they
// are skipped rather than treated as the end.
const FIRST_REAL_GRAPHIC = 2;

// A template names its graphic; the game knows it by a number, and so do the
// sprite sheet and the nudge table. The sheet is where the two meet, and this
// is the same rule examples/filmation/graphics.py uses -- the Python names
// them on the way into rooms.json and puts the numbers back on the way out, so
// the two have to agree or a castle is built from the wrong pieces.
// tests/room_model_test.js holds them together.
//
// The number stays the identity: several numbers can share one frame and they
// are NOT interchangeable, because the pixel nudge is per number. A shared
// frame's name therefore takes the number with it.
const UNNAMED_PREFIX = 'gfx_';

function graphicNames(sheet) {
  const out = new Map();
  const zx = sheet && sheet.meta && sheet.meta.zx;
  const map = zx && zx.game && zx.game.graphicMap;
  const sprites = (zx && zx.sprites) || [];
  if (!map) return out;

  const sharing = new Map();
  map.forEach(function (n, graphic) {
    if (n === null || n === undefined) return;
    if (!sharing.has(n)) sharing.set(n, []);
    sharing.get(n).push(graphic);
  });
  map.forEach(function (n, graphic) {
    if (n === null || n === undefined || !sprites[n]) return;
    const label = sprites[n].label;
    out.set(graphic, sharing.get(n).length === 1
      ? label : label + '.g' + graphic);
  });
  return out;
}

function graphicNumbers(sheet) {
  const out = new Map();
  for (const [graphic, name] of graphicNames(sheet)) out.set(name, graphic);
  return out;
}

// A template may name a graphic the sheet has nothing for -- four of
// Pentagram's do, all in templates no room places -- and graphics.py writes
// those as gfx_NN so a castle can still say what it is built from.
function graphicNumberOf(numbers, name) {
  if (numbers && numbers.has(name)) return numbers.get(name);
  if (typeof name === 'string' && name.startsWith(UNNAMED_PREFIX)) {
    const n = parseInt(name.slice(UNNAMED_PREFIX.length), 16);
    if (!Number.isNaN(n)) return n;
  }
  return -1;
}

// Scenery that nothing can ever be behind, drawn first and never sorted. The
// engine reads this off OBJ_BACKGROUND, which rooms_source.py sets by template
// name -- so the same names have to be listed here, or the preview sorts a
// wall that the game does not. tests/room_model_test.js holds the two together
// by reading the generated room_data.s back.
const BACKGROUND_TEMPLATES = {
  knightlore: ['scenery_walls_', 'scenery_trees_'],
  pentagram: [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 20, 21]
    .map(function (n) { return 'scenery_' + (n < 10 ? '0' : '') + n; })
};

// Knight Lore's castle is a 16 x 16 grid and the room number is a row and a
// column in it: north is a row on, east a column, and east and west wrap
// inside the row rather than carrying into it. player_exit in knightlore's
// player.s does this arithmetic, and every one of the 260 doorways in the data
// has a matching one in the room it lands on. Pentagram stores a destination
// on each doorway instead and needs none of this.
const GRID_WIDTH = 16;

// The four directions a doorway faces, in the order the arch templates come
// in, so the index falls out of the bottom two bits of the template number.
// room.s keeps them in this order too.
const DIRECTIONS = ['n', 'e', 's', 'w'];

// The artwork a castle is drawn with, named in meta.sprites so that the file
// says what it is drawn with instead of the host assuming.
//
// A room's template carries a GRAPHIC NUMBER, which is the game's own index and
// means nothing without the sheet that numbers itself the same way -- sheet and
// castle have to come from the same extraction or every piece is the wrong
// shape. rooms.py writes these; a file from before they existed has none, so
// the names it used to assume are the fallback and nothing breaks.
//
// The paths are relative to rooms.json, and a host resolves them itself: it is
// the one that knows whether it is reading a directory or a workspace, and the
// one that has to refuse a path that climbs out of the tree.
const SPRITE_FILES = {
  sheet: 'sprites.png',         // the artwork
  atlas: 'sprites.json',        // ...and which rectangle each graphic is
  adjust: 'sprite_adj.s'        // the per-graphic pixel nudge, from adj.py
};

function spriteFilesOf(atlas) {
  const said = (atlas && atlas.meta && atlas.meta.sprites) || {};
  const out = {};
  for (const key of Object.keys(SPRITE_FILES)) {
    out[key] = typeof said[key] === 'string' && said[key] ? said[key] : SPRITE_FILES[key];
  }
  return out;
}

// --- reading and writing --------------------------------------------------

function parseAtlas(text) {
  const atlas = JSON.parse(text);
  if (!atlas || typeof atlas !== 'object') throw new Error('not an object');
  for (const key of ['sizes', 'sceneryTemplates', 'objectTemplates', 'rooms']) {
    if (!Array.isArray(atlas[key])) throw new Error('no ' + key + ' array');
  }
  return atlas;
}

// Python writes the file with json.dumps(atlas, indent=1) and a trailing
// newline, and rooms.py will rewrite it whenever room_data.bin moves on. Match
// that byte for byte so the two are interchangeable and a save that changed one
// room does not rewrite all twelve thousand lines of the diff.
//
// Including the line endings, which on Windows are CRLF: Path.write_text opens
// in text mode, so every "\n" the generator writes reaches the disk as "\r\n".
// The caller says which to use -- the editor knows its document's own -- and
// eolOf reads it off the text that was loaded.
function serializeAtlas(atlas, eol) {
  const text = JSON.stringify(atlas, null, 1) + '\n';
  return eol === '\r\n' ? text.replace(/\n/g, '\r\n') : text;
}

function eolOf(text) {
  return text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
}

function gameOf(atlas) {
  return (atlas.meta && atlas.meta.game) || '';
}

function byName(templates) {
  const out = new Map();
  for (const t of templates) out.set(t.name, t);
  return out;
}

function byNumber(rooms) {
  const out = new Map();
  for (const r of rooms) out.set(r.number, r);
  return out;
}

function isBackgroundTemplate(game, name) {
  const names = BACKGROUND_TEMPLATES[game] || [];
  for (const n of names) if (name === n || name.startsWith(n)) return true;
  return false;
}

// --- expanding a room -----------------------------------------------------

// A piece of scenery carries absolute world coordinates and needs nothing from
// the room it is in.
function pieceFromBlock(block, numbers, template, index) {
  return {
    graphic: graphicNumberOf(numbers, block.graphic),
    graphicName: block.graphic,
    u: block.u, v: block.v, z: block.z,
    sizeU: block.sizeU, sizeV: block.sizeV, sizeZ: block.sizeZ,
    mirrored: !!(block.flags && block.flags.mirrored),
    kind: 'scenery',
    template: template.name,
    entry: index
  };
}

// room_unpack: a template entry plus one packed position, in world units. An
// object takes its place from the room and carries only a nudge of its own --
// half a cell along U or V, and a raise in Z, which is the template's and so
// moves every object drawn from it.
function pieceFromEntry(entry, position, floorZ, numbers, template, index) {
  const nudge = entry.offsets || {};
  const u = position.u * CELL + (nudge.halfU ? HALF_CELL : 0) + CELL_ORIGIN;
  const v = position.v * CELL + (nudge.halfV ? HALF_CELL : 0) + CELL_ORIGIN;
  // The mask is room_unpack's: it adds the nudge byte whole and drops its two
  // low bits again, so the half-cell bits never reach the height.
  const z = floorZ + ((position.z * LEVEL_Z + (nudge.raiseZ || 0)) & Z_MASK);
  return {
    graphic: graphicNumberOf(numbers, entry.graphic),
    graphicName: entry.graphic,
    u: u, v: v, z: z,
    sizeU: entry.sizeU, sizeV: entry.sizeV, sizeZ: entry.sizeZ,
    mirrored: !!(entry.flags && entry.flags.mirrored),
    kind: 'object',
    template: template.name,
    entry: index,
    cell: { u: position.u, v: position.v, z: position.z }
  };
}

function sizeOf(atlas, room) {
  return atlas.sizes[room.size] || atlas.sizes[0];
}

// Every piece a room puts in the pool, in the order room_build.s adds them:
// all the scenery first, template by template, then the object groups. The
// order matters -- it is the order the background run ends up in, and the
// order the depth list is built from.
function expandRoom(atlas, room, numbers) {
  const game = gameOf(atlas);
  const scenery = byName(atlas.sceneryTemplates);
  const objects = byName(atlas.objectTemplates);
  const floorZ = sizeOf(atlas, room).z;
  const pieces = [];

  room.scenery.forEach(function (ref, refIndex) {
    const template = scenery.get(ref.template);
    if (!template) return;
    const background = isBackgroundTemplate(game, template.name);
    template.blocks.forEach(function (block, i) {
      const piece = pieceFromBlock(block, numbers, template, i);
      if (piece.graphic < FIRST_REAL_GRAPHIC) return;
      piece.background = background;
      piece.ref = refIndex;
      pieces.push(piece);
    });
  });

  room.objects.forEach(function (group, refIndex) {
    const template = objects.get(group.template);
    if (!template) return;
    group.positions.forEach(function (position, slot) {
      template.entries.forEach(function (entry, i) {
        const piece = pieceFromEntry(entry, position, floorZ, numbers, template, i);
        if (piece.graphic < FIRST_REAL_GRAPHIC) return;
        piece.background = false;
        piece.ref = refIndex;
        piece.slot = slot;
        pieces.push(piece);
      });
    });
  });

  return pieces;
}

// How many records a room fills, which is what ROOM_MAX_OBJECTS is the worst
// of. Counted the way rooms_source.py counts it -- every entry of every
// template, graphic 1 included, because room_build steps over those too.
function poolUsed(atlas, room) {
  const scenery = byName(atlas.sceneryTemplates);
  const objects = byName(atlas.objectTemplates);
  let n = 0;
  for (const ref of room.scenery) {
    const t = scenery.get(ref.template);
    if (t) n += t.blocks.length;
  }
  for (const group of room.objects) {
    const t = objects.get(group.template);
    if (t) n += group.positions.length * t.entries.length;
  }
  return n;
}

// --- the map --------------------------------------------------------------

// Which way a doorway faces, or null if the template is not one.
//
// Knight Lore decides by INDEX, not by name -- room_door_note in its
// room_build.s is handed the number the room's record names and nothing else,
// so renaming a template in rooms.json cannot change what is a doorway. The
// first eight are the four arches plain and among the trees, in north, east,
// south, west order, so the side is the bottom two bits; the two high arches
// are a doorway on a tall room's walkway and only ever face east or south;
// their bases are not doorways, and neither are the gates. Pentagram says so
// outright, on the template.
const KL_PLAIN_ARCHES = 8;      // indices 0-7, side in bits 0-1
const KL_HIGH_ARCH_E = 20;      // BG_HIGH_ARCH_E, and BG_HIGH_ARCH_S after it
const KL_HIGH_ARCH_S = 21;

function doorwayOf(atlas, template) {
  if (gameOf(atlas) === 'pentagram') {
    return template.doorway ? template.side : null;
  }
  const index = template.index;
  if (index < KL_PLAIN_ARCHES) return DIRECTIONS[index & 3];
  if (index === KL_HIGH_ARCH_E) return 'e';
  if (index === KL_HIGH_ARCH_S) return 's';
  return null;
}

// Where a doorway leads. Knight Lore computes it: north is a row on, east a
// column, and the two floor directions wrap inside their own row or column
// rather than carrying into the next. Pentagram reads the byte, which is the
// authority -- one of its south doorways is an exit in twenty-eight rooms and
// walled up in one, and only the byte says which.
function destinationOf(atlas, room, ref, side) {
  if (gameOf(atlas) === 'pentagram') {
    return ref.destination || null;
  }
  const row = room.number & 0xF0;
  const column = room.number & 0x0F;
  switch (side) {
    case 'n': return ((room.number + GRID_WIDTH) & 0xFF);
    case 's': return ((room.number - GRID_WIDTH) & 0xFF);
    case 'e': return row | ((column + 1) & 0x0F);
    case 'w': return row | ((column - 1) & 0x0F);
    default: return null;
  }
}

// Every doorway in the game, as links from one room to another. A link whose
// destination is no room at all is kept and marked, because that is a fault
// worth showing rather than hiding.
function roomMap(atlas) {
  const scenery = byName(atlas.sceneryTemplates);
  const rooms = byNumber(atlas.rooms);
  const links = [];
  for (const room of atlas.rooms) {
    room.scenery.forEach(function (ref, refIndex) {
      const template = scenery.get(ref.template);
      if (!template) return;
      const side = doorwayOf(atlas, template);
      if (!side) return;
      const to = destinationOf(atlas, room, ref, side);
      if (to === null) return;
      links.push({
        from: room.number, to: to, side: side, ref: refIndex,
        template: template.name, exists: rooms.has(to)
      });
    });
  }
  return { rooms: atlas.rooms.map(function (r) { return r.number; }), links: links };
}

// A link is reciprocated when the room it lands on has a doorway facing back.
// In Knight Lore that is a property of the arithmetic and the artwork agreeing;
// in Pentagram it is 288 of the 289 destination bytes. Either way a doorway
// with no way back is worth knowing about.
function unreciprocated(map) {
  const back = new Set();
  for (const link of map.links) back.add(link.to + '>' + link.from);
  return map.links.filter(function (link) {
    return !back.has(link.from + '>' + link.to);
  });
}

// --- checks ---------------------------------------------------------------

// Everything that would stop rooms_source.py emitting the castle, or stop the
// engine building a room once it had. These are the emitters' own assertions,
// said early and all at once rather than as a traceback on the next build.
function checkAtlas(atlas, numbers) {
  const game = gameOf(atlas);
  const problems = [];
  const scenery = byName(atlas.sceneryTemplates);
  const objects = byName(atlas.objectTemplates);
  const seen = new Set();
  let previous = -1;

  // Where every doorway leads, worked out once. A door that leads nowhere is
  // a fault; a door with nothing facing back is only a warning, because it
  // builds and plays -- you simply cannot come back through it. The castle as
  // shipped has none of either, which is what makes both worth saying.
  const map = roomMap(atlas);
  const oneWay = new Set();
  for (const link of unreciprocated(map)) oneWay.add(link.from + '>' + link.to);
  const doorsOf = new Map();
  for (const link of map.links) {
    if (!doorsOf.has(link.from)) doorsOf.set(link.from, []);
    doorsOf.get(link.from).push(link);
  }

  function fault(room, text) {
    problems.push({ room: room, severity: 'error', text: text });
  }
  function note(room, text) {
    problems.push({ room: room, severity: 'warning', text: text });
  }

  // A template naming a graphic the sheet has no number for cannot be built:
  // rooms_source.py has nothing to put in the record's first byte. Only worth
  // saying when there is a sheet to check against.
  for (const group of numbers ? [
    { list: atlas.sceneryTemplates, key: 'blocks' },
    { list: atlas.objectTemplates, key: 'entries' }
  ] : []) {
    for (const template of group.list) {
      for (const entry of template[group.key] || []) {
        if (graphicNumberOf(numbers, entry.graphic) < 0) {
          problems.push({
            room: null, severity: 'error',
            text: template.name + ' names the graphic ' + entry.graphic +
                  ', which the sprite sheet has no number for'
          });
        }
      }
    }
  }

  for (const room of atlas.rooms) {
    const n = room.number;
    if (seen.has(n)) fault(n, 'two rooms are numbered ' + n);
    seen.add(n);
    // room_find walks the records and stops at the first number at least the
    // one it wants, so out-of-order records are simply not found.
    if (n < previous) fault(n, 'out of order: it follows room ' + previous);
    previous = n;

    if (room.ink < 0 || room.ink > 7) fault(n, 'ink ' + room.ink + ' is not 0-7');
    if (!atlas.sizes[room.size]) fault(n, 'no room shape ' + room.size);

    // The scenery count shares the attribute byte with the ink and the shape.
    // Knight Lore stores it as it is, in bits 5-7; Pentagram stores it less
    // one, which is what lets a room have eight.
    const most = game === 'pentagram' ? 8 : 7;
    if (room.scenery.length > most) {
      fault(n, room.scenery.length + ' scenery entries; the count field holds ' + most);
    }
    if (game === 'pentagram' && room.scenery.length < 1) {
      fault(n, 'no scenery: the count is stored less one, so a room needs at least one');
    }

    let body = 0;
    for (const ref of room.scenery) {
      const t = scenery.get(ref.template);
      if (!t) { fault(n, 'no scenery template called ' + ref.template); continue; }
      body += game === 'pentagram' && t.doorway ? 2 : 1;
    }
    for (const group of room.objects) {
      const t = objects.get(group.template);
      if (!t) { fault(n, 'no object template called ' + group.template); continue; }
      const count = group.positions.length;
      // The group byte carries the repeat count in its bottom three bits, so a
      // group places between one and eight; more than that is another group.
      if (count < 1 || count > CELLS) {
        fault(n, group.template + ' places ' + count + '; a group holds 1 to ' + CELLS);
      }
      for (const p of group.positions) {
        if (p.u < 0 || p.u >= CELLS || p.v < 0 || p.v >= CELLS || p.z < 0 || p.z >= LEVELS) {
          fault(n, group.template + ' at ' + p.u + ',' + p.v + ',' + p.z + ' is off the grid');
        }
      }
      body += 1 + count;
    }

    // The record's skip is one byte, counted from its own length field.
    const skip = 2 + body;
    if (skip > 255) fault(n, 'the record is ' + skip + ' bytes; the skip byte holds 255');

    for (const link of doorsOf.get(n) || []) {
      if (!link.exists) {
        fault(n, 'the ' + link.side + ' doorway leads to room ' + link.to +
                 ', which is not a room');
      } else if (oneWay.has(link.from + '>' + link.to)) {
        note(n, 'the ' + link.side + ' doorway leads to room ' + link.to +
                ', which has no doorway back');
      }
    }

    const used = poolUsed(atlas, room);
    if (used === 0) note(n, 'nothing in it');
  }

  if (game === 'knightlore' && previous !== 0xFF) {
    problems.push({
      room: null, severity: 'error',
      text: 'the last room must be $FF: the walk has no end marker and stops at ' +
            'the first number at least the one it wants'
    });
  }
  return problems;
}

// --- changing it ----------------------------------------------------------
//
// Every one of these edits the atlas in place and returns what it did, or null
// when it did nothing. The caller serialises the whole file afterwards: the
// document is the model, so there is no change list to keep and undo is the
// editor's own. None of them enforces a limit -- checkAtlas says what is wrong
// and the designer shows it, which is friendlier than refusing a move that is
// on its way somewhere legal.

// A group holds one template and up to eight positions, because the repeat
// count lives in the bottom three bits of the group byte. So an object joins a
// group of its own template that has room, and starts a new group when none
// has. That is also how the game's own data reads: room 0 of Knight Lore holds
// two object_block groups because the first filled up.
const GROUP_LIMIT = 8;

function addObject(room, templateName, cell) {
  for (const group of room.objects) {
    if (group.template === templateName && group.positions.length < GROUP_LIMIT) {
      group.positions.push({ u: cell.u, v: cell.v, z: cell.z });
      return { ref: room.objects.indexOf(group), slot: group.positions.length - 1 };
    }
  }
  room.objects.push({
    template: templateName,
    positions: [{ u: cell.u, v: cell.v, z: cell.z }]
  });
  return { ref: room.objects.length - 1, slot: 0 };
}

function removeObject(room, ref, slot) {
  const group = room.objects[ref];
  if (!group || !group.positions[slot]) return null;
  group.positions.splice(slot, 1);
  // An empty group would still cost its own byte and place nothing.
  if (!group.positions.length) room.objects.splice(ref, 1);
  return { ref: ref, slot: slot };
}

function moveObject(room, ref, slot, cell) {
  const group = room.objects[ref];
  if (!group) return null;
  const position = group.positions[slot];
  if (!position) return null;
  position.u = cell.u;
  position.v = cell.v;
  position.z = cell.z;
  return position;
}

// Which template a placed object is drawn from. Moving it to another means
// taking it out of its group and putting it in one of the new template's,
// because a group is one template's own.
function retemplateObject(room, ref, slot, templateName) {
  const group = room.objects[ref];
  if (!group || !group.positions[slot]) return null;
  const cell = group.positions[slot];
  const moved = { u: cell.u, v: cell.v, z: cell.z };
  removeObject(room, ref, slot);
  return addObject(room, templateName, moved);
}

// Scenery is a bare template in Knight Lore and a template plus the room a
// doorway leads to in Pentagram. The destination is written for both -- rooms.py
// only emits it for Pentagram, and rooms_source.py asserts it is zero on
// anything that is not a doorway -- so it is only added where the file already
// has the field.
function addScenery(atlas, room, templateName, destination) {
  const entry = { template: templateName };
  if (gameOf(atlas) === 'pentagram') entry.destination = destination || 0;
  room.scenery.push(entry);
  return room.scenery.length - 1;
}

function removeScenery(room, ref) {
  if (!room.scenery[ref]) return null;
  return room.scenery.splice(ref, 1)[0];
}

// Renaming a template is the point of the file being JSON: the names in
// Pentagram's are placeholders until someone works out what each piece is. The
// rooms name templates by name, so every reference moves with it.
function renameTemplate(atlas, from, to) {
  if (from === to) return 0;
  const taken = byName(atlas.sceneryTemplates).has(to) ||
                byName(atlas.objectTemplates).has(to);
  if (taken) return null;
  let moved = 0;
  for (const group of [atlas.sceneryTemplates, atlas.objectTemplates]) {
    for (const template of group) {
      if (template.name === from) { template.name = to; moved++; }
    }
  }
  if (!moved) return null;
  for (const room of atlas.rooms) {
    for (const ref of room.scenery) {
      if (ref.template === from) { ref.template = to; moved++; }
    }
    for (const ref of room.objects) {
      if (ref.template === from) { ref.template = to; moved++; }
    }
  }
  return moved;
}

// The fields a template entry is made of, and what each may hold. The designer
// edits these by name; rooms_source.py puts the record back together from them.
const ENTRY_FIELDS = {
  blocks: ['u', 'v', 'z', 'sizeU', 'sizeV', 'sizeZ'],
  entries: ['sizeU', 'sizeV', 'sizeZ']
};
const FLAG_FIELDS = ['mirrored', 'passable'];
const NUDGE_FIELDS = ['halfU', 'halfV'];

// One field of one entry. `field` is a plain name, or flags.<bit> and
// offsets.<name> for the two nested groups. Values are clamped to a byte
// because that is what every one of them ends up as.
function setTemplateField(template, key, entryIndex, field, value) {
  const entry = template[key] && template[key][entryIndex];
  if (!entry) return null;
  const dot = field.indexOf('.');
  if (dot < 0) {
    if ((ENTRY_FIELDS[key] || []).indexOf(field) < 0) return null;
    entry[field] = value & 0xFF;
    return entry;
  }
  const group = field.slice(0, dot);
  const name = field.slice(dot + 1);
  if (group === 'flags') {
    if (!entry.flags) entry.flags = { mirrored: false, passable: false, rest: 0 };
    if (FLAG_FIELDS.indexOf(name) >= 0) entry.flags[name] = !!value;
    else if (name === 'rest') entry.flags.rest = value & 0xFF;
    else return null;
    return entry;
  }
  if (group === 'offsets') {
    if (!entry.offsets) entry.offsets = { halfU: false, halfV: false, raiseZ: 0 };
    if (NUDGE_FIELDS.indexOf(name) >= 0) entry.offsets[name] = !!value;
    // The raise is added into Z and masked with $FC, so only multiples of four
    // survive -- room_unpack drops the two low bits with the nudge bits.
    else if (name === 'raiseZ') entry.offsets.raiseZ = value & Z_MASK;
    else return null;
    return entry;
  }
  return null;
}

// Which graphic an entry is drawn from, by name. Refused rather than guessed
// when the name is not in the table: a graphic with no number cannot be built.
function setTemplateGraphic(numbers, template, key, entryIndex, name) {
  const entry = template[key] && template[key][entryIndex];
  if (!entry || graphicNumberOf(numbers, name) < 0) return null;
  entry.graphic = name;
  return entry;
}

// How much of the game one template accounts for: the rooms that name it and
// the objects they place from it.
//
// Worth having because a template is shared. Its placement nudge -- half a cell
// along U or V, and a raise in Z, all in the one byte at the end of an entry --
// belongs to the template and not to any position, so changing it moves every
// object drawn from it, everywhere. The designer says how many that is rather
// than letting someone discover it a room at a time.
function templateUsage(atlas, name) {
  let rooms = 0;
  let placements = 0;
  for (const room of atlas.rooms) {
    let here = 0;
    for (const group of room.objects) {
      if (group.template === name) here += group.positions.length;
    }
    for (const ref of room.scenery) {
      if (ref.template === name) here += 1;
    }
    if (here) { rooms++; placements += here; }
  }
  return { rooms: rooms, placements: placements };
}

// Whether a template is named by any room, which is what rooms_source.py uses
// to decide whether to emit it at all. Kept fresh here so the designer can grey
// out the ones nothing uses, and so the flag in the file stays true.
function refreshUsage(atlas) {
  const named = new Set();
  for (const room of atlas.rooms) {
    for (const ref of room.scenery) named.add(ref.template);
    for (const ref of room.objects) named.add(ref.template);
  }
  for (const group of [atlas.sceneryTemplates, atlas.objectTemplates]) {
    for (const template of group) template.used = named.has(template.name);
  }
  return named;
}

// The fullest room, which is what the object pool has to hold: ROOM_MAX_OBJECTS
// in the generated source, and ROOM_SLOTS in the game's memory map.
function poolNeeded(atlas) {
  let most = 0;
  let where = null;
  for (const room of atlas.rooms) {
    const used = poolUsed(atlas, room);
    if (used > most) { most = used; where = room.number; }
  }
  return { slots: most, room: where };
}

if (typeof module !== 'undefined') {
  module.exports = {
    CELL, CELL_ORIGIN, HALF_CELL, CELLS, LEVELS, LEVEL_Z, Z_MASK,
    FIRST_REAL_GRAPHIC, GRID_WIDTH, DIRECTIONS,
    KL_PLAIN_ARCHES, KL_HIGH_ARCH_E, KL_HIGH_ARCH_S,
    BACKGROUND_TEMPLATES,
    SPRITE_FILES, spriteFilesOf, graphicNumbers, graphicNames, graphicNumberOf,
    UNNAMED_PREFIX,
    ENTRY_FIELDS, FLAG_FIELDS, NUDGE_FIELDS,
    parseAtlas, serializeAtlas, gameOf, byName, byNumber,
    isBackgroundTemplate, expandRoom, poolUsed, sizeOf, eolOf,
    doorwayOf, destinationOf, roomMap, unreciprocated,
    GROUP_LIMIT, addObject, removeObject, moveObject, retemplateObject,
    addScenery, removeScenery, renameTemplate, refreshUsage,
    setTemplateField, setTemplateGraphic,
    templateUsage,
    checkAtlas, poolNeeded
  };
}
