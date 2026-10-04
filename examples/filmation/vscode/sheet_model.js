// What a Filmation game's two graphics files say, and nothing about what is
// done with it.
//
//   sprites.json    the sheet: the PNG it goes with, what its colours mean,
//                   how the game's own bytes are laid out, and a group tree of
//                   every sprite's rectangle in the picture
//   graphics.json   the table the game indexes by: which sprite each graphic
//                   number draws, and the pixel nudge that lines it up
//
// A sprite's name IS its path through the group tree -- sabreman.legs.1 is the
// sprite called "1" in the group "legs" inside the group "sabreman" -- so this
// is the one place that spells a name out, and everything else takes names as
// given. Both files are written once by sprite_sheet.py and edited by hand
// after that; nothing regenerates them.
//
// Three readers want all this -- the room designer's model and its renderer,
// and the graphic map's editor -- so it lives here rather than three times
// over. Each page inlines it as source.
//
// No DOM and no vscode API, so it runs under plain Node for the tests. The
// page gets it inlined, which is why nothing here may use require() and why
// the export at the bottom is guarded.

'use strict';

// What puts a sprite on one of the other sheets graphics.json lists under
// "sheets": furniture:GrandfatherClockNE.2 is the sprite "2" in the group
// "GrandfatherClockNE" of the sheet graphics.json calls "furniture". A name
// without one is on the game's own sheet. examples/filmation/scripts/sheet.py
// reads the same names for the build.
// var, not const: each page inlines this file and then graphic_map_model.js,
// whose require() line declares the same name again.
var SHEET_SEPARATOR = ':';  // eslint-disable-line no-var

// Every sprite in the sheet, in the order the tree lists them -- which is the
// order the picture lays them out, and the order the build emits them.
//
// `onSheet` is the sheet's name when it is one of the others, which goes on
// the front of every name and group; each sprite says which sheet it is on
// ('' for the game's own), so a drawer knows which picture to cut it from.
function spriteList(sheet, onSheet) {
  const out = [];
  const prefix = onSheet ? onSheet + SHEET_SEPARATOR : '';

  function walk(node, path) {
    for (const key of Object.keys((node && node.sprites) || {})) {
      const box = node.sprites[key];
      out.push({
        name: prefix + path.concat([key]).join('.'),
        group: prefix + path.join('.'),
        sheet: onSheet || '',
        x: box.x, y: box.y, w: box.w, h: box.h
      });
    }
    for (const group of Object.keys((node && node.group) || {})) {
      walk(node.group[group], path.concat([group]));
    }
  }

  walk(sheet || {}, []);
  return out;
}

// The other sheets a graphics.json lists: name -> its file, relative to the
// graphics.json. Lightkeep lists Melkhior's Mansion's, one a category.
function sheetsOf(graphics) {
  const said = (graphics && graphics.sheets) || {};
  const out = {};
  for (const name of Object.keys(said)) {
    if (typeof said[name] === 'string') out[name] = said[name];
  }
  return out;
}

// Every sprite there is to draw from: the game's own sheet's, then each
// other's in the order graphics.json lists them. `others` maps a sheet's name
// to what its file says, and may be left out.
function allSprites(sheet, others) {
  let out = spriteList(sheet);
  for (const name of Object.keys(others || {})) {
    out = out.concat(spriteList(others[name], name));
  }
  return out;
}

// ...and by name, which is how graphics.json refers to them.
function spritesByName(sheet, others) {
  const out = new Map();
  for (const sprite of allSprites(sheet, others)) out.set(sprite.name, sprite);
  return out;
}

// graphic number -> what graphics.json says about it: the sprite it draws (a
// name, or absent), its box and its nudge. A graphic can carry a nudge and no
// sprite; Knight Lore's graphic 1 does, and it is not a fault.
//
// The FILE is keyed by the graphic's name and carries the number as a field.
// That way round because rooms.json refers to graphics by name, and a name
// that appeared in no file could not be searched for or checked by eye. The
// number is still the game's identity -- sprite_table is indexed by it -- so
// everything that draws works in numbers, and this is where the two meet.
// Each entry is given its `name`, so a reader that has the number has both.
function graphicTable(graphics) {
  const out = new Map();
  const said = (graphics && graphics.graphics) || {};
  for (const name of Object.keys(said)) {
    const entry = said[name] || {};
    if (Number.isInteger(entry.number)) {
      out.set(entry.number, Object.assign({ name: name }, entry));
    }
  }
  return out;
}

// ...and by name, which is how rooms.json refers to them.
function graphicsByName(graphics) {
  const out = new Map();
  const said = (graphics && graphics.graphics) || {};
  for (const name of Object.keys(said)) out.set(name, said[name] || {});
  return out;
}

// What each graphic is called, which is what rooms.json refers to it by.
//
// The name is simply the key it sits under: graphics.json is the one place a
// graphic is named, and examples/filmation/scripts/graphics.py reads exactly the same
// thing for the build. It used to be worked out here from the sprite, with the
// number stuck on the end where several graphics shared one bitmap -- so a
// castle referred to names that were written down nowhere.
//
// Only graphics that draw something are named, because only those can be
// placed. tests/room_model_test.js requires this and graphics.py to agree name
// for name; a castle built from one and named by the other would be built out
// of the wrong pieces.
function graphicNamesOf(sheet, graphics) {
  const out = new Map();
  for (const [number, entry] of graphicTable(graphics)) {
    if (typeof entry.sprite === 'string') out.set(number, entry.name);
  }
  return out;
}

// What box each graphic occupies, by the name rooms.json calls it: half-widths
// along the two ground axes and a height, which is what the engine sorts and
// collides with. It belongs to the graphic rather than to the template that
// places one, which is why it lives in graphics.json.
function graphicSizes(sheet, graphics) {
  const out = new Map();
  for (const [name, entry] of graphicsByName(graphics)) {
    const box = entry.size;
    if (box) out.set(name, { u: box.u, v: box.v, z: box.z });
  }
  return out;
}

// ...and the box a particular template entry sits in.
//
// Mirroring reflects a piece across the isometric axis, so the two ground axes
// trade places and U and V swap; the height never changes. The stored box is
// the unmirrored one, because every doorway in the game is placed both ways
// round and the file would otherwise have to state it twice.
//
// An entry may carry sizeU/sizeV/sizeZ of its own, and then it means them.
// That is for the bytes that are not a box at all: Knight Lore's guard
// templates end with a blank, passable, zero-height entry whose U and V are
// the guard's patrol extent. Null where nothing says -- the caller decides
// whether that is worth complaining about, since a room still has to draw.
function boxOf(sizes, entry) {
  if (entry.sizeU !== undefined) {
    return { u: entry.sizeU, v: entry.sizeV, z: entry.sizeZ };
  }
  const box = sizes && sizes.get(entry.graphic);
  if (!box) return null;
  if (entry.flags && entry.flags.mirrored) {
    return { u: box.v, v: box.u, z: box.z };
  }
  return { u: box.u, v: box.v, z: box.z };
}

// Everything a drawer needs, worked out once: a graphic number to the
// rectangle it comes out of, and the nudge it is placed with. A drawer that
// has only the game's own picture leaves `others` out, and a graphic drawn
// from another sheet is then one it has no sprite for -- not one cut from the
// wrong picture.
function sheetIndex(sheet, graphics, others) {
  const byName = spritesByName(sheet, others);
  const table = graphicTable(graphics);
  return { byName: byName, table: table, sprites: spriteList(sheet) };
}

// Which rectangle of the PNG a graphic is drawn from, or null where the game
// never uses that number -- or uses it without a bitmap.
function spriteFor(index, graphic) {
  const entry = index.table.get(graphic);
  if (!entry || typeof entry.sprite !== 'string') return null;
  const sprite = index.byName.get(entry.sprite);
  if (!sprite) return null;
  return {
    sprite: sprite.name,
    group: sprite.group,
    sheet: sprite.sheet,
    rect: { x: sprite.x, y: sprite.y, w: sprite.w, h: sprite.h },
    width: sprite.w,
    height: sprite.h
  };
}

// The animations the sheet names, as lists of sprite names in playing order.
// The order is written out because it is not the sprites' own: a walk goes out
// and back, 1 2 3 4 3 2.
function animationsOf(sheet) {
  const out = new Map();
  const said = (sheet && sheet.animations) || {};
  for (const name of Object.keys(said)) {
    if (Array.isArray(said[name])) out.set(name, said[name].slice());
  }
  return out;
}

// What the sheet's colours mean, and how the game's own bytes are laid out.
// Kept whole rather than picked apart: the one reader that wants it -- a tool
// packing the picture back into the game's format -- wants all of it.
function formatOf(sheet) {
  return {
    file: ((sheet && sheet.sheet) || {}).file || 'sprites.png',
    colours: ((sheet && sheet.sheet) || {}).colours || {},
    bytes: (sheet && sheet.bytes) || {}
  };
}

if (typeof module !== 'undefined') {
  module.exports = {
    SHEET_SEPARATOR, spriteList, sheetsOf, allSprites, spritesByName,
    graphicTable, graphicsByName, graphicNamesOf,
    graphicSizes, boxOf,
    sheetIndex, spriteFor, animationsOf, formatOf
  };
}
