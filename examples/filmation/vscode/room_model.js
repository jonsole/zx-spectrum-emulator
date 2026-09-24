// The room designer's pure half: what a Filmation castle is, what a room
// expands to, how its rooms join up, and what would stop it building.
//
// The file it works on is examples/filmation/<game>/rooms.json, which is the
// editable form of a game's rooms. rooms.py decodes the game's own tables into
// it and rooms_source.py turns it back into room_data.s, so a change made here
// reaches the build without going anywhere near the original bytes. Both games
// write the same schema; where they differ is written down below rather than
// branched on twice -- and a castle that says its own rules in its meta, as
// knightlore128's does, is read by those instead (see rulesOf).
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
// (node examples/filmation/vscode/tests/room_model_test.js). The page gets it inlined as
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

// sheet_model.js is the one place that knows what the two graphics files look
// like -- see the note in room_render.js about why this is pulled in twice
// over.
if (typeof require !== 'undefined' && typeof module !== 'undefined') {
  // eslint-disable-next-line no-var, vars-on-top
  var { graphicNamesOf, graphicSizes, boxOf } = require('./sheet_model');
}

// A graphic is named after the sprite it draws, with the number on the end
// where several graphics draw one sprite. examples/filmation/graphics.py does
// the same in Python for the build, and tests/room_model_test.js requires the
// two to agree name for name -- a castle built from one and named by the other
// would be built out of the wrong pieces.
function graphicNames(sheet, graphics) {
  return graphicNamesOf(sheet, graphics);
}

// The box each graphic occupies, by name. It used to be repeated on every
// template entry; graphics.json holds it now, and sheet_model has the rule for
// reading one back -- including the U/V swap a mirrored piece wants.
function graphicBoxes(sheet, graphics) {
  return graphicSizes(sheet, graphics);
}

function graphicNumbers(sheet, graphics) {
  const out = new Map();
  for (const [graphic, name] of graphicNames(sheet, graphics)) {
    out.set(name, graphic);
  }
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
//
// These are the two original games' rules, and only the fallback: a castle
// whose templates.json lists its own in meta.background is taken at its word,
// by exact name, the way knightlore128's rooms_source.py reads the same list.
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
  atlas: 'sprites.json',        // ...and which rectangle each sprite is
  graphics: 'graphics.json',    // ...and which sprite each graphic draws
};

// All three come out of the extraction ONCE and are the authoritative form
// afterwards; nothing regenerates them. Each is one thing: the PNG is the
// pixels, sprites.json says where every sprite sits in it, and graphics.json
// is the table the game indexes by -- which sprite each graphic number draws,
// the nudge that lines that bitmap up, and the box it occupies.

function spriteFilesOf(atlas) {
  const said = (atlas && atlas.meta && atlas.meta.sprites) || {};
  const out = {};
  for (const key of Object.keys(SPRITE_FILES)) {
    out[key] = typeof said[key] === 'string' && said[key] ? said[key] : SPRITE_FILES[key];
  }
  return out;
}

// --- reading and writing --------------------------------------------------

// A castle is two files, one job each: rooms.json is the rooms and the floor
// shapes, templates.json the castle-wide pieces the rooms place. Both editors
// work on ONE castle in memory, the two merged -- rooms with the template
// groups in them -- the way examples/filmation/castle.py's read_castle does
// for the build, and each writes back only the file it owns.
const TEMPLATE_GROUPS = ['sceneryTemplates', 'objectTemplates'];
// What rooms.py calls the two when it first writes them. After that each file
// names the other in its meta, and readers follow those names -- these are
// only what a writer puts there when it has nothing else to go on.
const TEMPLATES_FILE = 'templates.json';
const ROOMS_FILE = 'rooms.json';

function mustBeBlock(said, key) {
  if (!said || typeof said !== 'object' || Array.isArray(said)) {
    throw new Error('no ' + key + ' block');
  }
}

// rooms.json. The floor shapes are keyed by name; the rooms are a list,
// because a room's identity is its number and the order is the game's.
function parseAtlas(text) {
  const atlas = JSON.parse(text);
  if (!atlas || typeof atlas !== 'object') throw new Error('not an object');
  mustBeBlock(atlas.roomDimensions, 'roomDimensions');
  if (!Array.isArray(atlas.rooms)) throw new Error('no rooms array');
  // Until a templates file is merged in, there are no templates to name.
  for (const group of TEMPLATE_GROUPS) {
    if (atlas[group] === undefined) atlas[group] = {};
  }
  return atlas;
}

// templates.json.
function parseTemplates(text) {
  const templates = JSON.parse(text);
  if (!templates || typeof templates !== 'object') throw new Error('not an object');
  for (const group of TEMPLATE_GROUPS) mustBeBlock(templates[group], group);
  return templates;
}

// The castle: the rooms with the templates in them. The templates' own header
// comes along as templatesMeta, so writing them back gives the file the header
// it had. Shared, not copied -- an edit to a template in the castle is an edit
// to the templates it came from.
function withTemplates(atlas, templates) {
  for (const group of TEMPLATE_GROUPS) {
    atlas[group] = (templates && templates[group]) || {};
  }
  atlas.templatesMeta = (templates && templates.meta) || null;
  return atlas;
}

// Where a castle's templates are, as rooms.json says in its meta -- or null
// if it does not say, because nothing is assumed about it.
function templatesFileOf(atlas) {
  const said = atlas && atlas.meta && atlas.meta.templates;
  return typeof said === 'string' && said ? said : null;
}

// ...and which rooms a templates file belongs to, as it says in its own.
function roomsFileOf(templates) {
  const said = templates && templates.meta && templates.meta.rooms;
  return typeof said === 'string' && said ? said : null;
}

// Why two files are not one castle, or null if they are: each has to name the
// other. Two castles' files paired by mistake would build rooms out of the
// wrong pieces, so this is checked rather than trusted. The names are the
// files' own, without their directory.
function pairProblem(roomsName, atlas, templatesName, templates) {
  const said = templatesFileOf(atlas);
  if (!said) return roomsName + ' does not say where its templates are (meta.templates)';
  if (said !== templatesName) {
    return roomsName + ' names ' + said + ' as its templates, not ' + templatesName;
  }
  const back = roomsFileOf(templates);
  if (!back) return templatesName + ' does not say which rooms it belongs to (meta.rooms)';
  if (back !== roomsName) {
    return templatesName + ' belongs to ' + back + ', not to ' + roomsName;
  }
  return null;
}

// The twins of castle.py's format_rooms and format_templates, and they have
// to stay twins: rooms.py rewrites these files whenever room_data.bin moves
// on, and if the two sides laid them out differently then saving one room in
// the designer would rewrite the whole diff. A placement is one record and
// belongs on one line; JSON.stringify(atlas, null, 1) spreads each across
// nine. tests/room_model_test.js requires both games' real files to come back
// out of these byte for byte.
//
// Including the line endings, which on Windows are CRLF: Path.write_text opens
// in text mode, so every "\n" the generator writes reaches the disk as "\r\n".
// The caller says which to use -- the editor knows its document's own -- and
// eolOf reads it off the text that was loaded.

// rooms.json: the header, the floor shapes and the rooms. Not the templates,
// which are templates.json's.
function serializeAtlas(atlas, eol) {
  const out = ['{', ' "meta": ' + block(atlas.meta, 1) + ',', ''];

  const shapes = Object.keys(atlas.roomDimensions || {});
  out.push(' "roomDimensions": {');
  const shapeWidth = widest(shapes) + 3;
  shapes.forEach(function (name, i) {
    out.push('  ' + pad('"' + name + '":', shapeWidth) + ' ' +
             flat(atlas.roomDimensions[name]) +
             (i < shapes.length - 1 ? ',' : ''));
  });
  out.push(' },');

  out.push('');
  out.push(' "rooms": [');
  (atlas.rooms || []).forEach(function (room, i) {
    const lines = roomLines(room, '  ');
    if (i < atlas.rooms.length - 1) lines[lines.length - 1] += ',';
    for (const one of lines) out.push(one);
  });
  out.push(' ]');
  out.push('}');
  return withEol(out.join('\n') + '\n', eol);
}

// templates.json: a template to a name, a piece to a line.
function serializeTemplates(atlas, eol) {
  const meta = atlas.templatesMeta || {
    version: 1,
    game: gameOf(atlas),
    rooms: ROOMS_FILE,
    comment: 'The castle\u2019s templates: pieces every room naming one is ' +
             'built from. rooms.json places them.'
  };
  const out = ['{', ' "meta": ' + block(meta, 1)];
  TEMPLATE_GROUPS.forEach(function (group, g) {
    out[out.length - 1] += ',';
    out.push('');
    out.push(' "' + group + '": {');
    const names = Object.keys(atlas[group] || {});
    names.forEach(function (name, i) {
      const comma = i < names.length - 1 ? ',' : '';
      const pieces = atlas[group][name] || [];
      if (!pieces.length) { out.push('  "' + name + '": []' + comma); return; }
      out.push('  "' + name + '": [');
      pieces.forEach(function (piece, j) {
        const lines = placement(piece, '   ');
        if (j < pieces.length - 1) lines[lines.length - 1] += ',';
        for (const one of lines) out.push(one);
      });
      out.push('  ]' + comma);
    });
    out.push(' }');
  });
  out.push('}');
  return withEol(out.join('\n') + '\n', eol);
}

function withEol(text, eol) {
  return eol === '\r\n' ? text.replace(/\n/g, '\r\n') : text;
}

function pad(text, width) {
  return text.length >= width ? text : text + ' '.repeat(width - text.length);
}

// The longest name in a group, which the keys are padded out to: the Python
// side writes "%-*s" % (max + 3, '"name":'), and the three is the two quotes
// and the colon.
function widest(names) {
  let most = 0;
  for (const name of names) if (name.length > most) most = name.length;
  return most;
}

// One value, the way JSON spells it. Only the scalars a castle holds -- and a
// list of them, which a templates file's meta.background is, on one line with
// a space after each comma the way castle.py's _scalar writes it.
// JSON.stringify would leave the spaces out and rewrite the line on every save.
function scalar(value) {
  if (typeof value === 'string') return '"' + value + '"';
  if (Array.isArray(value)) return '[' + value.map(scalar).join(', ') + ']';
  return JSON.stringify(value);
}

// A mapping on one line, in the order its keys were written.
function flat(said) {
  return '{ ' + Object.keys(said).map(function (key) {
    return '"' + key + '": ' + scalar(said[key]);
  }).join(', ') + ' }';
}

// One placement: its graphic and where it goes, then its named bits, each kept
// whole on a line of its own rather than run past a hundred characters.
const PLACE_HEAD = ['u', 'v', 'z', 'sizeU', 'sizeV', 'sizeZ'];

function placement(piece, indent) {
  const head = ['"graphic": ' + scalar(piece.graphic)];
  for (const key of PLACE_HEAD) {
    if (piece[key] !== undefined) head.push('"' + key + '": ' + scalar(piece[key]));
  }
  const lines = [indent + '{ ' + head.join(', ')];
  for (const key of ['flags', 'offsets']) {
    if (piece[key] !== undefined) {
      lines[lines.length - 1] += ',';
      lines.push(indent + '  "' + key + '": ' + flat(piece[key]));
    }
  }
  lines[lines.length - 1] += ' }';
  return lines;
}

// One room: what it is on a line, then what stands in it.
function roomLines(room, indent) {
  const head = ['number', 'ink', 'dimensions'].filter(function (key) {
    return room[key] !== undefined;
  }).map(function (key) { return '"' + key + '": ' + scalar(room[key]); });
  const lines = [indent + '{ ' + head.join(', ') + ','];

  const scenery = room.scenery || [];
  if (!scenery.length) {
    lines.push(indent + '  "scenery": [],');
  } else {
    lines.push(indent + '  "scenery": [');
    scenery.forEach(function (ref, i) {
      lines.push(indent + '   ' + flat(ref) + (i < scenery.length - 1 ? ',' : ''));
    });
    lines.push(indent + '  ],');
  }

  const objects = room.objects || [];
  if (!objects.length) {
    lines.push(indent + '  "objects": []');
    lines.push(indent + '}');
    return lines;
  }
  lines.push(indent + '  "objects": [');
  objects.forEach(function (group, i) {
    const spots = group.positions || [];
    lines.push(indent + '   { "template": ' + scalar(group.template) +
               ', "positions": [');
    spots.forEach(function (spot, j) {
      lines.push(indent + '    ' + flat(spot) + (j < spots.length - 1 ? ',' : ''));
    });
    lines.push(indent + '   ] }' + (i < objects.length - 1 ? ',' : ''));
  });
  lines.push(indent + '  ]');
  lines.push(indent + '}');
  return lines;
}

// A nested mapping, one key to a line: the meta block and nothing else.
function block(said, depth) {
  const indent = ' '.repeat(depth);
  const keys = Object.keys(said || {});
  const lines = ['{'];
  keys.forEach(function (key, i) {
    const comma = i < keys.length - 1 ? ',' : '';
    const value = said[key];
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      lines.push(indent + ' "' + key + '": ' + block(value, depth + 1) + comma);
    } else {
      lines.push(indent + ' "' + key + '": ' + scalar(value) + comma);
    }
  });
  lines.push(indent + '}');
  return lines.join('\n');
}

function eolOf(text) {
  return text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
}

function gameOf(atlas) {
  return (atlas.meta && atlas.meta.game) || '';
}

// What to call a game in a panel's title. A game not listed is called by the
// directory name its meta gives, which is at least what it is.
const GAME_TITLES = {
  knightlore: 'Knight Lore',
  knightlore128: 'Knight Lore 128K',
  pentagram: 'Pentagram'
};

function gameTitle(atlas) {
  const game = gameOf(atlas || {});
  return GAME_TITLES[game] || game || 'Filmation';
}

// A room number the way the game's source writes it: two hex digits.
function hexByte(n) {
  return n.toString(16).toUpperCase().padStart(2, '0');
}

// Templates, by the name rooms call them by. rooms.json keys them that way
// already -- a template IS its list of placements -- so this is the file's own
// mapping, kept as a Map for the has/get the rest of this file does.
//
// The key ORDER is the game's table order: bits of a room's record index that
// table, so a template may be renamed but not moved.
function byName(templates) {
  const out = new Map();
  for (const name of Object.keys(templates || {})) out.set(name, templates[name]);
  return out;
}

// ...and the index the game knows a template by, which is where its name sits.
function templateIndex(templates) {
  const out = new Map();
  Object.keys(templates || {}).forEach(function (name, i) { out.set(name, i); });
  return out;
}

function byNumber(rooms) {
  const out = new Map();
  for (const r of rooms) out.set(r.number, r);
  return out;
}

// Whether a scenery template is background: drawn first and never sorted.
// The castle's own list when its templates file has one, and then only a name
// on it counts -- the built-in lists match by prefix because they were written
// for templates rooms.py named, and a castle that says its own has no such
// naming to lean on.
function isBackgroundTemplate(atlas, name) {
  const said = atlas && atlas.templatesMeta && atlas.templatesMeta.background;
  if (Array.isArray(said)) return said.indexOf(name) >= 0;
  const names = BACKGROUND_TEMPLATES[gameOf(atlas || {})] || [];
  for (const n of names) if (name === n || name.startsWith(n)) return true;
  return false;
}

// --- expanding a room -----------------------------------------------------

// A piece of scenery carries absolute world coordinates and needs nothing from
// the room it is in.
function pieceFromBlock(block, numbers, sizes, templateName, index) {
  const box = boxOf(sizes, block) || { u: 0, v: 0, z: 0 };
  return {
    graphic: graphicNumberOf(numbers, block.graphic),
    graphicName: block.graphic,
    u: block.u, v: block.v, z: block.z,
    sizeU: box.u, sizeV: box.v, sizeZ: box.z,
    mirrored: !!(block.flags && block.flags.mirrored),
    kind: 'scenery',
    template: templateName,
    entry: index
  };
}

// room_unpack: a template entry plus one packed position, in world units. An
// object takes its place from the room and carries only a nudge of its own --
// half a cell along U or V, and a raise in Z, which is the template's and so
// moves every object drawn from it.
function pieceFromEntry(entry, position, floorZ, numbers, sizes,
                        templateName, index) {
  const nudge = entry.offsets || {};
  const box = boxOf(sizes, entry) || { u: 0, v: 0, z: 0 };
  const u = position.u * CELL + (nudge.halfU ? HALF_CELL : 0) + CELL_ORIGIN;
  const v = position.v * CELL + (nudge.halfV ? HALF_CELL : 0) + CELL_ORIGIN;
  // The mask is room_unpack's: it adds the nudge byte whole and drops its two
  // low bits again, so the half-cell bits never reach the height.
  const z = floorZ + ((position.z * LEVEL_Z + (nudge.raiseZ || 0)) & Z_MASK);
  return {
    graphic: graphicNumberOf(numbers, entry.graphic),
    graphicName: entry.graphic,
    u: u, v: v, z: z,
    sizeU: box.u, sizeV: box.v, sizeZ: box.z,
    mirrored: !!(entry.flags && entry.flags.mirrored),
    kind: 'object',
    template: templateName,
    entry: index,
    cell: { u: position.u, v: position.v, z: position.z }
  };
}

// The floor a room stands on: how far it reaches along U and V from the
// centre, and its height. A room NAMES one of the shapes rooms.json lists
// rather than indexing them, because "square" says what a room is and "0"
// does not -- but the order of that list is still the game's own, since bits
// 3 and 4 of the attribute byte index room_size_tbl straight.
//
// The first is the fallback, for a room naming a shape the file has not got:
// the designer still has to draw something, and checkAtlas says so separately.
function dimensionsOf(atlas) {
  const out = new Map();
  const said = (atlas && atlas.roomDimensions) || {};
  for (const name of Object.keys(said)) out.set(name, said[name]);
  return out;
}

function sizeOf(atlas, room) {
  const shapes = dimensionsOf(atlas);
  return shapes.get(room.dimensions) || shapes.values().next().value;
}

// Every piece a room puts in the pool, in the order room_build.s adds them:
// all the scenery first, template by template, then the object groups. The
// order matters -- it is the order the background run ends up in, and the
// order the depth list is built from.
function expandRoom(atlas, room, numbers, sizes) {
  const scenery = byName(atlas.sceneryTemplates);
  const objects = byName(atlas.objectTemplates);
  const floorZ = sizeOf(atlas, room).z;
  const pieces = [];

  room.scenery.forEach(function (ref, refIndex) {
    const template = scenery.get(ref.template);
    if (!template) return;
    const background = isBackgroundTemplate(atlas, ref.template);
    template.forEach(function (block, i) {
      const piece = pieceFromBlock(block, numbers, sizes, ref.template, i);
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
      template.forEach(function (entry, i) {
        const piece = pieceFromEntry(entry, position, floorZ, numbers,
                                     sizes, group.template, i);
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
    if (t) n += t.length;
  }
  for (const group of room.objects) {
    const t = objects.get(group.template);
    if (t) n += group.positions.length * t.length;
  }
  return n;
}

// --- the castle's rules ---------------------------------------------------
//
// How a castle's rooms join up, and what its builder will take, used to be
// keyed on the game's name: Knight Lore's rooms are a grid and Pentagram's
// doorways carry a byte. A castle can now say its own in rooms.json's
// meta.rules, which is how knightlore128 -- Knight Lore's castle, joined by a
// table instead of the grid -- gets its rules without the designer learning
// its name:
//
//   exits           "table": every scenery entry is two bytes, a template and
//                   a destination, and a doorway's destination is the room it
//                   leads to -- 0 included, since 0 is a room -- or null for
//                   one walled up. Anything else, or nothing, is the game's
//                   own rule below.
//   sceneryPerRoom  the most scenery entries a room may have.
//   lastRoom        the number the last room must have: a builder that walks
//                   the records to the first number at least the one it wants
//                   needs one at the end that every search stops at.
//
// A castle that says nothing -- Knight Lore's and Pentagram's -- falls back on
// what the designer always knew about those two, so their files behave
// exactly as before. rulesOf is the one place either is read.
const EXITS_TABLE = 'table';

function isByte(value) {
  return Number.isInteger(value) && value >= 0 && value <= 0xFF;
}

function rulesOf(atlas) {
  const game = gameOf(atlas || {});
  const said = (atlas && atlas.meta && atlas.meta.rules) || {};
  // Pentagram stores its scenery count less one, which is what lets a room
  // have eight; Knight Lore stores it as it is, in three bits.
  const scenery = game === 'pentagram' ? 8 : 7;
  return {
    // 'table' as above; 'byte', Pentagram's destination byte, where 0 is no
    // way out; 'grid', Knight Lore's arithmetic on the room number.
    exits: said.exits === EXITS_TABLE ? 'table' : game === 'pentagram' ? 'byte' : 'grid',
    sceneryPerRoom: isByte(said.sceneryPerRoom) ? said.sceneryPerRoom : scenery,
    // null when nothing constrains it. Only Knight Lore's walk needed one of
    // the games that say nothing.
    lastRoom: isByte(said.lastRoom) ? said.lastRoom : game === 'knightlore' ? 0xFF : null,
    lastRoomSaid: isByte(said.lastRoom),
    // How many bytes start an object group: 1 for the games' own, the template
    // in the top five bits and the count in the bottom three; 2 for a castle
    // whose builder reads the template and the count as a byte each, which is
    // what lets it have more than 32 object templates.
    groupBytes: said.groupBytes === 2 ? 2 : 1
  };
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

// Which wall a doorway template stands in, or null if it is not one.
//
// Decided by the template's POSITION in the table, as the games decide it:
// Knight Lore's room_build.s tests the index (`cp 8`, then the two high
// arches), and Pentagram's builder reads a destination byte after exactly the
// scenery indices in rooms.py's DOOR_INDICES. The names say the same thing
// today, but a name can be edited in the templates panel and the game's code
// cannot, so it is not trusted for this. examples/filmation/castle.py has the
// same table for the build.
//
// That is the rule for those two games only. A castle whose templates.json
// has meta.doorways -- template name to wall -- is taken at its word, by
// name, as castle.py's side_of takes it: its builder reads a table made from
// that list rather than testing the index, so any template can be a doorway,
// and a rename has to carry the name across (renameTemplate does).
const DOORWAYS = {
  knightlore: (function () {
    const out = new Map();
    for (let i = 0; i < 8; i++) out.set(i, DIRECTIONS[i & 3]);
    out.set(20, 'e');
    out.set(21, 's');
    return out;
  }()),
  pentagram: (function () {
    const out = new Map();
    for (const i of [0, 1, 2, 3, 4, 5, 6, 7, 24, 25, 26, 27]) {
      out.set(i, DIRECTIONS[i & 3]);
    }
    return out;
  }())
};

// The walls a castle's own templates file names, or null if it names none.
function doorwaysSaid(atlas) {
  const said = atlas && atlas.templatesMeta && atlas.templatesMeta.doorways;
  return said && typeof said === 'object' && !Array.isArray(said) ? said : null;
}

function doorwayOf(atlas, templateName) {
  const said = doorwaysSaid(atlas);
  if (said) {
    // A wall that is not one of the four is no doorway here; checkAtlas says
    // so, because the builder refuses it.
    const side = Object.prototype.hasOwnProperty.call(said, templateName)
      ? said[templateName] : null;
    return DIRECTIONS.indexOf(side) >= 0 ? side : null;
  }
  const rule = DOORWAYS[gameOf(atlas)];
  if (!rule) return null;
  const at = templateIndex(atlas.sceneryTemplates).get(templateName);
  return at === undefined ? null : (rule.get(at) || null);
}

// Where a doorway leads. Knight Lore computes it: north is a row on, east a
// column, and the two floor directions wrap inside their own row or column
// rather than carrying into the next. Pentagram reads the byte, which is the
// authority -- one of its south doorways is an exit in twenty-eight rooms and
// walled up in one, and only the byte says which. A castle whose exits are a
// table reads the destination too, but there 0 is a room like any other, so
// only null (or no destination at all) walls a doorway up.
function destinationOf(atlas, room, ref, side) {
  const exits = rulesOf(atlas).exits;
  if (exits === 'table') {
    return Number.isInteger(ref.destination) ? ref.destination : null;
  }
  if (exits === 'byte') {
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
      const side = doorwayOf(atlas, ref.template);
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

// Every doorway in one room, walled up or not, in the order the room lists
// its scenery. roomMap leaves a walled-up doorway out, because it goes nowhere
// -- but in a castle whose exits are a table, a walled-up doorway is exactly
// the one someone is about to give a destination, so the designer needs it.
function doorwaysOf(atlas, room) {
  const rooms = byNumber(atlas.rooms);
  const out = [];
  room.scenery.forEach(function (ref, refIndex) {
    const side = doorwayOf(atlas, ref.template);
    if (!side) return;
    const to = destinationOf(atlas, room, ref, side);
    out.push({
      from: room.number, to: to, side: side, ref: refIndex,
      template: ref.template, exists: to !== null && rooms.has(to)
    });
  });
  return out;
}

// One cell of the map in each direction, north up: y grows northwards.
const MAP_STEP = {
  n: { x: 0, y: 1 },
  e: { x: 1, y: 0 },
  s: { x: 0, y: -1 },
  w: { x: -1, y: 0 }
};

// A map drawn from the doorways themselves, for a castle whose room numbers
// are not places. Knight Lore's number is a row and a column, so its map is
// the number; Pentagram's is a list. A castle joined by a table has only its
// doorways to say where anything is, so this walks them.
//
// Breadth first from the first room, which stands at 0,0: a room goes one
// cell north, east, south or west of the room whose doorway first reaches it
// with that cell still free. A castle need not be flat -- a doorway can lead
// round a corner the grid cannot draw, or back into a cell already taken --
// so a room no doorway can put in a free cell is left out of the grid and
// listed in `unplaced`, along with any room no doorway reaches at all. Nothing
// is moved to make room: the first placement stands, which keeps the layout
// the same from one render to the next.
//
// Returns the placed rooms as {number, x, y} in the order they were placed,
// the unplaced numbers in the castle's order, and the bounding box of the
// placed ones.
function mapLayout(atlas) {
  const leads = new Map();
  for (const link of roomMap(atlas).links) {
    if (!link.exists) continue;
    if (!leads.has(link.from)) leads.set(link.from, []);
    leads.get(link.from).push(link);
  }

  const at = new Map();         // room number -> its cell
  const taken = new Set();      // "x,y" of every cell with a room in it
  const placed = [];
  function place(number, x, y) {
    at.set(number, { x: x, y: y });
    taken.add(x + ',' + y);
    placed.push({ number: number, x: x, y: y });
  }

  if (atlas.rooms.length) place(atlas.rooms[0].number, 0, 0);
  // `placed` is the queue as well: a room's doorways are walked once it is
  // on the map, in the order the rooms went on.
  for (let next = 0; next < placed.length; next++) {
    const from = placed[next];
    for (const link of leads.get(from.number) || []) {
      if (at.has(link.to)) continue;
      const step = MAP_STEP[link.side];
      const x = from.x + step.x;
      const y = from.y + step.y;
      if (taken.has(x + ',' + y)) continue;
      place(link.to, x, y);
    }
  }

  const unplaced = [];
  for (const room of atlas.rooms) {
    if (!at.has(room.number)) unplaced.push(room.number);
  }
  let minX = 0, maxX = 0, minY = 0, maxY = 0;
  for (const cell of placed) {
    if (cell.x < minX) minX = cell.x;
    if (cell.x > maxX) maxX = cell.x;
    if (cell.y < minY) minY = cell.y;
    if (cell.y > maxY) maxY = cell.y;
  }
  return {
    placed: placed, unplaced: unplaced,
    minX: minX, maxX: maxX, minY: minY, maxY: maxY,
    width: placed.length ? maxX - minX + 1 : 0,
    height: placed.length ? maxY - minY + 1 : 0
  };
}

// --- checks ---------------------------------------------------------------

// Everything that would stop rooms_source.py emitting the castle, or stop the
// engine building a room once it had. These are the emitters' own assertions,
// said early and all at once rather than as a traceback on the next build.
function checkAtlas(atlas, numbers) {
  const game = gameOf(atlas);
  const rules = rulesOf(atlas);
  const table = rules.exits === 'table';
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
  for (const group of numbers
    ? [atlas.sceneryTemplates, atlas.objectTemplates] : []) {
    for (const name of Object.keys(group || {})) {
      for (const entry of group[name] || []) {
        if (graphicNumberOf(numbers, entry.graphic) < 0) {
          problems.push({
            room: null, severity: 'error',
            text: name + ' names the graphic ' + entry.graphic +
                  ', which graphics.json has no number for'
          });
        }
      }
    }
  }

  // A templates file that names its own doorways names them by template and
  // wall, and the builder stops on either being wrong: a wall that is not one
  // of the four, or a template the castle does not have -- which is what a
  // rename done by hand in one file and not the other leaves behind.
  const doorways = doorwaysSaid(atlas);
  for (const name of doorways ? Object.keys(doorways) : []) {
    if (!scenery.has(name)) {
      problems.push({
        room: null, severity: 'error',
        text: 'templates.json names ' + name + ' as a doorway, and there is no ' +
              'such scenery template'
      });
    } else if (DIRECTIONS.indexOf(doorways[name]) < 0) {
      problems.push({
        room: null, severity: 'error',
        text: 'templates.json gives ' + name + ' the wall ' +
              JSON.stringify(doorways[name]) + '; a wall is one of ' + DIRECTIONS.join(', ')
      });
    }
  }

  // A destination byte needs a value that means "no way out", and in a table
  // that is a number no room has -- so one has to be left free.
  if (table && atlas.rooms.length > 0xFF) {
    problems.push({
      room: null, severity: 'error',
      text: 'every room number is taken, and one is needed to mean no exit'
    });
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
    if (!dimensionsOf(atlas).has(room.dimensions)) {
      fault(n, 'no floor shape called ' + JSON.stringify(room.dimensions));
    }

    // The scenery count shares the attribute byte with the ink and the shape.
    // Knight Lore stores it as it is, in bits 5-7; Pentagram stores it less
    // one, which is what lets a room have eight. A castle that says its own
    // limit in meta.rules is held to that instead.
    const most = rules.sceneryPerRoom;
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
      if (table) {
        // Every entry is a template and a destination, doorway or not: the
        // builder reads the pair and asks the template whether it is a door.
        body += 2;
        const going = ref.destination !== undefined && ref.destination !== null;
        if (!doorwayOf(atlas, ref.template)) {
          if (going) fault(n, ref.template + ' is not a doorway, and has a destination');
        } else if (going && !isByte(ref.destination)) {
          fault(n, 'the ' + ref.template + ' doorway leads to ' +
                   JSON.stringify(ref.destination) + ', which is not a room number');
        }
        continue;
      }
      body += game === 'pentagram' && t.doorway ? 2 : 1;
    }
    for (const group of room.objects) {
      const t = objects.get(group.template);
      if (!t) { fault(n, 'no object template called ' + group.template); continue; }
      const count = group.positions.length;
      // The games' group byte carries the repeat count in its bottom three bits,
      // so a group places between one and eight; more than that is another
      // group. A castle with two-byte groups keeps the same limit.
      if (count < 1 || count > CELLS) {
        fault(n, group.template + ' places ' + count + '; a group holds 1 to ' + CELLS);
      }
      for (const p of group.positions) {
        if (p.u < 0 || p.u >= CELLS || p.v < 0 || p.v >= CELLS || p.z < 0 || p.z >= LEVELS) {
          fault(n, group.template + ' at ' + p.u + ',' + p.v + ',' + p.z + ' is off the grid');
        }
      }
      body += rules.groupBytes + count;
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

  if (rules.lastRoomSaid && previous !== rules.lastRoom) {
    problems.push({
      room: null, severity: 'error',
      text: 'the last room must be $' + hexByte(rules.lastRoom) + ' (' + rules.lastRoom +
            '), as meta.rules.lastRoom says: the walk stops at the first number ' +
            'at least the one it wants, so every search has to meet it'
    });
  } else if (!rules.lastRoomSaid && game === 'knightlore' && previous !== 0xFF) {
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
//
// A castle whose exits are a table has the field on doorways only: its
// builder refuses a destination on anything else. A new doorway there is
// walled up -- null -- until someone says where it goes, because 0 is a room
// and would quietly send it to one.
function addScenery(atlas, room, templateName, destination) {
  const entry = { template: templateName };
  const exits = rulesOf(atlas).exits;
  if (exits === 'table') {
    if (doorwayOf(atlas, templateName)) {
      entry.destination = isByte(destination) ? destination : null;
    }
  } else if (exits === 'byte') {
    entry.destination = destination || 0;
  }
  room.scenery.push(entry);
  return room.scenery.length - 1;
}

// Which template a scenery entry places. In a castle whose exits are a table
// the destination field goes with being a doorway: a door changed into a wall
// loses it, since the builder refuses one there, and a wall changed into a
// door gains one, walled up until it is set.
function setSceneryTemplate(atlas, ref, templateName) {
  ref.template = templateName;
  if (rulesOf(atlas).exits !== 'table') return ref;
  if (!doorwayOf(atlas, templateName)) delete ref.destination;
  else if (ref.destination === undefined) ref.destination = null;
  return ref;
}

function removeScenery(room, ref) {
  if (!room.scenery[ref]) return null;
  return room.scenery.splice(ref, 1)[0];
}

// --- adding a room --------------------------------------------------------

// Why a room cannot be numbered this, or null if it can. Unlike the edits
// above, these are refused rather than left to checkAtlas: a number is the
// room's identity, and a room made under a number it cannot have is not on
// its way to anything legal.
function addRoomProblem(atlas, number) {
  if (!isByte(number)) return 'a room number is 0 to 255';
  if (byNumber(atlas.rooms).has(number)) return 'there is already a room ' + number;
  const rules = rulesOf(atlas);
  if (rules.lastRoom !== null && number > rules.lastRoom) {
    return 'room ' + number + ' would come after room $' + hexByte(rules.lastRoom) +
           ' (' + rules.lastRoom + '), which has to be the last';
  }
  // A table's "no exit" is a number no room has, so one is always kept free.
  if (rules.exits === 'table' && atlas.rooms.length >= 0xFF) {
    return 'the last free number is needed to mean no exit';
  }
  return null;
}

// The lowest number a new room could have, or null if there is none.
function firstFreeRoom(atlas) {
  for (let n = 0; n <= 0xFF; n++) {
    if (!addRoomProblem(atlas, n)) return n;
  }
  return null;
}

// A new, empty room: no scenery, no objects, standing on the first floor
// shape. Its ink is the room before it's, or failing that the one after --
// every room the games ship is ink 2 to 7, bright on black, and taking a
// neighbour's keeps it one you can see and in keeping with the rooms around
// it. The rooms stay in ascending order, because room_find walks them and
// stops at the first number at least the one it wants.
//
// Returns the new room's index in atlas.rooms, or why it could not be made.
function addRoom(atlas, number) {
  const problem = addRoomProblem(atlas, number);
  if (problem) return problem;
  let at = 0;
  while (at < atlas.rooms.length && atlas.rooms[at].number < number) at++;
  const beside = atlas.rooms[at - 1] || atlas.rooms[at];
  const room = {
    number: number,
    ink: beside ? beside.ink : 7,
    dimensions: Object.keys(atlas.roomDimensions || {})[0],
    scenery: [],
    objects: []
  };
  atlas.rooms.splice(at, 0, room);
  return at;
}

// Renaming a template is the point of the file being JSON: the names in
// Pentagram's are placeholders until someone works out what each piece is. The
// rooms name templates by name, so every reference moves with it.
function renameTemplate(atlas, from, to) {
  if (from === to) return 0;
  // Held to what an assembler label can be, and unique across both tables.
  if (templateNameProblem(atlas, to)) return null;

  // The name is the key, and the key order is the game's table order -- so the
  // group is rebuilt in place rather than the entry deleted and re-added,
  // which would move the template to the end of the table and renumber every
  // room's reference to everything after it.
  let moved = 0;
  for (const group of [atlas.sceneryTemplates, atlas.objectTemplates]) {
    if (!group || !Object.prototype.hasOwnProperty.call(group, from)) continue;
    const rebuilt = {};
    for (const name of Object.keys(group)) {
      rebuilt[name === from ? to : name] = group[name];
      if (name === from) moved++;
    }
    for (const name of Object.keys(group)) delete group[name];
    for (const name of Object.keys(rebuilt)) group[name] = rebuilt[name];
  }
  if (!moved) return null;

  // A castle that names its doorways and its background in templates.json
  // names them by template, so those names move too -- or the rename would
  // quietly wall up every door made from the template. The doorway list is
  // rebuilt in its own order for the same reason as the table above: the file
  // is written back in that order.
  const doorways = doorwaysSaid(atlas);
  if (doorways && Object.prototype.hasOwnProperty.call(doorways, from)) {
    const rebuilt = {};
    for (const name of Object.keys(doorways)) {
      rebuilt[name === from ? to : name] = doorways[name];
    }
    for (const name of Object.keys(doorways)) delete doorways[name];
    for (const name of Object.keys(rebuilt)) doorways[name] = rebuilt[name];
  }
  const background = atlas.templatesMeta && atlas.templatesMeta.background;
  if (Array.isArray(background)) {
    for (let i = 0; i < background.length; i++) {
      if (background[i] === from) background[i] = to;
    }
  }

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

// The fields of a template entry the designer may edit by name, which
// rooms_source.py puts the record back together from.
//
// A block's own place in the world is one of them. Its SIZE is not: the box a
// piece occupies belongs to the graphic, and lives in graphics.json, so it is
// changed in the graphic map rather than once per template that happens to
// place one. An object entry has nothing left here at all -- it takes its
// place from the room -- and edits its flags and its nudge through the two
// groups below.
//
// An entry may still carry a box of its own, for the records whose bytes are
// not a box at all, and nothing here writes one or throws one away.
const ENTRY_FIELDS = {
  blocks: ['u', 'v', 'z'],
  entries: []
};
const FLAG_FIELDS = ['mirrored', 'passable'];
const NUDGE_FIELDS = ['halfU', 'halfV'];

// One field of one entry. `field` is a plain name, or flags.<bit> and
// offsets.<name> for the two nested groups. Values are clamped to a byte
// because that is what every one of them ends up as.
function setTemplateField(template, key, entryIndex, field, value) {
  const entry = template && template[entryIndex];
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
  const entry = template && template[entryIndex];
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

// Which templates any room names, which is what rooms_source.py uses to decide
// whether to emit one at all. Worked out rather than stored: the file used to
// carry a `used` flag on every template, and a flag derived from the rest of
// the file is only something to fall out of date with it.
function refreshUsage(atlas) {
  const named = new Set();
  for (const room of atlas.rooms) {
    for (const ref of room.scenery) named.add(ref.template);
    for (const ref of room.objects) named.add(ref.template);
  }
  return named;
}

// --- editing the templates themselves -------------------------------------
//
// A template's POSITION in its table is the game's own number for it, and the
// game's code leans on some of those numbers: Knight Lore's room_build.s takes
// scenery 0-7 to be the arches and BG_GATE_0..BG_GATE_3 to be a run, and its
// movers.s gives behaviour to particular object templates by label. So
// nothing here renumbers a template. A new one goes on the end of its table,
// and only the last one can be deleted -- anything else would shift every
// template after it, and the code would be pointing at the wrong ones.

// How many templates a table can hold. An object group in a room is one byte,
// the template in its top five bits and the repeat count in the bottom three,
// so 32. A scenery reference is a byte of its own, and $FF ends the section.
const TEMPLATE_LIMIT = { sceneryTemplates: 255, objectTemplates: 32 };

// ...and for a particular castle: one whose groups start with two bytes
// (meta.rules.groupBytes) gives the template a byte of its own, so 255.
function templateLimit(atlas, group) {
  if (group === 'objectTemplates' && rulesOf(atlas).groupBytes === 2) return 255;
  return TEMPLATE_LIMIT[group];
}

// A template's name becomes an assembler label -- BG_ARCH_N, FG_GUARD_EW -- so
// it is held to what a label can be.
const TEMPLATE_NAME = /^[a-z][a-z0-9_]*$/;

// Why a name cannot be used, or null if it can.
function templateNameProblem(atlas, name) {
  if (!TEMPLATE_NAME.test(name || '')) {
    return 'a name is lower-case letters, digits and underscores, starting with a letter';
  }
  if (byName(atlas.sceneryTemplates).has(name) || byName(atlas.objectTemplates).has(name)) {
    return name + ' is already a template';
  }
  return null;
}

// What a new piece starts as. Scenery stands at the middle of the floor, on
// it; an object takes its place from the room and has only its nudge.
function freshPiece(group, graphic) {
  const flags = { mirrored: false, passable: false, rest: 16 };
  if (group === 'sceneryTemplates') {
    return { graphic: graphic, u: 128, v: 128, z: 128, flags: flags };
  }
  return { graphic: graphic, flags: flags,
           offsets: { halfU: false, halfV: false, raiseZ: 0 } };
}

// A new, empty template on the end of its table. Returns its index, or null.
function newTemplate(atlas, group, name) {
  if (templateNameProblem(atlas, name)) return null;
  if (Object.keys(atlas[group]).length >= templateLimit(atlas, group)) return null;
  atlas[group][name] = [];
  return Object.keys(atlas[group]).length - 1;
}

// A copy of one, under a new name, on the end of its table. The copy is the
// pieces and nothing else: behaviour the game's code gives the original by
// label does not come with it.
function duplicateTemplate(atlas, group, from, to) {
  if (!Object.prototype.hasOwnProperty.call(atlas[group], from)) return null;
  const at = newTemplate(atlas, group, to);
  if (at === null) return null;
  atlas[group][to] = JSON.parse(JSON.stringify(atlas[group][from]));
  return at;
}

// Why a template cannot be deleted, or null if it can.
function deleteProblem(atlas, group, name) {
  const names = Object.keys(atlas[group]);
  if (names.indexOf(name) < 0) return 'no such template';
  if (refreshUsage(atlas).has(name)) return 'a room still places it';
  if (names[names.length - 1] !== name) {
    return 'only the last template can go: deleting one before it would ' +
           'renumber every template after, and the game\'s code refers to ' +
           'some of them by number';
  }
  return null;
}

function deleteTemplate(atlas, group, name) {
  if (deleteProblem(atlas, group, name)) return false;
  delete atlas[group][name];
  return true;
}

// The pieces of one template. These change every room that uses it, which is
// what the templates panel is for; the room panels never do it.
function addPiece(template, group, graphic) {
  template.push(freshPiece(group, graphic));
  return template.length - 1;
}

function removePiece(template, index) {
  if (index < 0 || index >= template.length) return false;
  template.splice(index, 1);
  return true;
}

// Order matters: scenery is laid in the order it is listed, and room_build
// adds a template's pieces to the object pool one after another.
function movePiece(template, from, to) {
  if (from < 0 || from >= template.length || to < 0 || to >= template.length) {
    return false;
  }
  const piece = template.splice(from, 1)[0];
  template.splice(to, 0, piece);
  return true;
}

// Move one piece of a template, by world units. What it can move by depends on
// what kind of piece it is.
//
// Scenery carries its own place in the world, three bytes, so it moves
// anywhere they reach. An object carries no place at all -- it takes one from
// the room -- only its nudge: half a cell along U and along V, on or off, and a
// raise in Z that room_unpack masks to a multiple of four. So an object piece
// moved along U has its half-cell switched on past the middle of the cell and
// off before it, and a raise is kept to what the game can hold.
//
// `from` is where the move started, for a drag that measures from the piece's
// place when it was picked up rather than piling small moves on each other.
function shiftPiece(template, group, at, move, from) {
  const piece = template && template[at];
  if (!piece) return false;
  const was = JSON.stringify(piece);
  const start = from || piece;
  const du = move.u || 0;
  const dv = move.v || 0;
  const dz = move.z || 0;
  if (group === 'sceneryTemplates') {
    piece.u = Math.max(0, Math.min(255, start.u + du));
    piece.v = Math.max(0, Math.min(255, start.v + dv));
    piece.z = Math.max(0, Math.min(255, start.z + dz));
  } else {
    const offsets = start.offsets || { halfU: false, halfV: false, raiseZ: 0 };
    const u = (offsets.halfU ? HALF_CELL : 0) + du;
    const v = (offsets.halfV ? HALF_CELL : 0) + dv;
    const raise = Math.max(0, Math.min(Z_MASK, (offsets.raiseZ || 0) + dz));
    piece.offsets = {
      halfU: u >= HALF_CELL / 2,
      halfV: v >= HALF_CELL / 2,
      raiseZ: raise & Z_MASK
    };
  }
  return JSON.stringify(piece) !== was;
}

// A drag on the picture, in screen pixels, back into world units at the
// piece's own height.
//
// The projection puts U + V across and (V - U) / 2 down-the-screen-negated, so
// across is exact and down is only to the nearest two units: a move whose
// V - U is odd has no screen position of its own. So U + V is made the move
// across exactly, and U - V the nearest value to twice the move down that has
// the same parity -- which U + V and U - V always must, being the same two
// integers added and taken away. Across then lands on the pixel, and down on
// it or one short.
function screenToWorld(dx, dy) {
  let apart = 2 * dy;
  if ((apart - dx) % 2 !== 0) apart += 1;
  return { u: (dx + apart) / 2, v: (dx - apart) / 2 };
}

// Every room that places a template, by number, in the castle's order.
function roomsUsing(atlas, name) {
  const out = [];
  for (const room of atlas.rooms) {
    const here = room.scenery.some(function (ref) { return ref.template === name; }) ||
                 room.objects.some(function (ref) { return ref.template === name; });
    if (here) out.push(room.number);
  }
  return out;
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
    DOORWAYS, TEMPLATE_LIMIT, templateLimit, templateNameProblem, newTemplate,
    duplicateTemplate, deleteProblem, deleteTemplate, addPiece,
    removePiece, movePiece, roomsUsing, shiftPiece, screenToWorld,
    BACKGROUND_TEMPLATES,
    SPRITE_FILES, spriteFilesOf, graphicNumbers, graphicNames, graphicBoxes,
    graphicNumberOf, templateIndex,
    UNNAMED_PREFIX,
    ENTRY_FIELDS, FLAG_FIELDS, NUDGE_FIELDS,
    parseAtlas, serializeAtlas, parseTemplates, serializeTemplates,
    withTemplates, templatesFileOf, roomsFileOf, pairProblem, TEMPLATES_FILE, ROOMS_FILE, gameOf, byName, byNumber,
    GAME_TITLES, gameTitle,
    isBackgroundTemplate, expandRoom, poolUsed, sizeOf, dimensionsOf, eolOf,
    rulesOf, doorwayOf, destinationOf, roomMap, unreciprocated, doorwaysOf,
    MAP_STEP, mapLayout,
    GROUP_LIMIT, addObject, removeObject, moveObject, retemplateObject,
    addScenery, setSceneryTemplate, removeScenery, renameTemplate, refreshUsage,
    addRoomProblem, firstFreeRoom, addRoom,
    setTemplateField, setTemplateGraphic,
    templateUsage,
    checkAtlas, poolNeeded
  };
}
