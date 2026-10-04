// What a Filmation graphic table is, and the edits you can make to one.
//
// examples/filmation/<game>/metadata/graphics.json is the table the game indexes by:
// for each of its graphic numbers, which sprite draws it and the pixel nudge
// that lines that bitmap up. It is the document this edits. sprites.json is
// read alongside, for the pictures and the names -- sheet_model.js is what
// knows the shape of both.
//
// Two things make it worth a picture rather than a text editor. It is numbers
// pointing at names, so nothing in the file says what graphic 30 looks like;
// and several numbers can name one sprite -- 42 of them do, in Knight Lore --
// which matters because those numbers are NOT interchangeable. The nudge is
// per graphic number, and 30 and 150 draw the same bitmap four rows apart.
//
// The number is the identity and cannot become implicit, because a graphic
// number is a STATE as well as a picture: 96 is a collectable lying in a room,
// 104 the same one in flight into the cauldron, 168 the one the bubbles are
// asking for. One bitmap, three numbers, three behaviours.
//
// No DOM and no vscode API, so it runs under plain Node for the tests
// (node examples/filmation/vscode/tests/graphic_map_model_test.js). The page gets it
// inlined as source, which is why nothing here may use require() and why the
// export at the bottom is guarded.

'use strict';

// sheet_model.js is the one place that knows the two files' shapes -- see the
// note in room_render.js about why it is pulled in the way it is.
if (typeof require !== 'undefined' && typeof module !== 'undefined') {
  // eslint-disable-next-line no-var, vars-on-top
  var { SHEET_SEPARATOR, spriteList, allSprites, spritesByName, graphicTable,
    graphicsByName } = require('./sheet_model');
  // eslint-disable-next-line no-var, vars-on-top
  var { floorPoint } = require('./room_render');
}

// How the packed form said "this graphic has no bitmap". Nothing writes it any
// more -- a graphic with no sprite simply has no `sprite` -- and it is here so
// that a file converted by hand from the old .bin is caught rather than
// quietly believed.
const NO_SPRITE = 255;

function parseMap(text) {
  return JSON.parse(text);
}

// ...and back out, laid out the way examples/filmation/scripts/graphics.py writes it:
// one graphic to a line, with the sprite and the box lined up into columns.
//
// Not JSON.stringify. The file is one people edit by hand, and a panel that
// reflowed all 187 lines the first time a graphic was re-pointed would make
// every change diff as the whole file. graphics.py's format_table is the other
// half of this, and tests/graphic_map_model_test.js requires both games' real
// files to come back out of it byte for byte.
function serializeMap(said, eol) {
  const table = (said && said.graphics) || {};
  // In the game's own table order, which is what `number` holds: the file
  // reads down the table the way the game indexes it, however the names are
  // later changed around.
  const names = Object.keys(table)
    .filter(function (key) { return Number.isInteger((table[key] || {}).number); })
    .sort(function (a, b) { return table[a].number - table[b].number; });

  const rows = [];
  for (const key of names) {
    const entry = table[key] || {};
    const cells = ['"number": ' + String(entry.number).padStart(3, ' ')];
    if (entry.sprite) cells.push('"sprite": "' + entry.sprite + '"');
    const box = entry.size;
    if (box) {
      cells.push('"size": { "u": ' + box.u + ', "v": ' + box.v +
                 ', "z": ' + box.z + ' }');
    }
    // A zero nudge is no nudge, and the overwhelming majority are.
    if (entry.x) cells.push('"x": ' + entry.x);
    if (entry.y) cells.push('"y": ' + entry.y);
    if (entry.mirrored) {
      cells.push('"mirrored": { "x": ' + entry.mirrored.x +
                 ', "y": ' + entry.mirrored.y + ' }');
    }
    if (entry.fixed) cells.push('"fixed": true');
    rows.push({ name: key, cells: cells });
  }

  const sheet = (said && said.sprites) || 'sprites.json';
  const lines = ['{', ' "sprites": "' + sheet + '",'];
  // The other sheets, carried through as they are: nothing here makes them.
  const others = (said && said.sheets) || {};
  const sheetNames = Object.keys(others);
  if (sheetNames.length) {
    let widest = 0;
    for (const name of sheetNames) widest = Math.max(widest, name.length);
    lines.push(' "sheets": {');
    sheetNames.forEach(function (name, i) {
      lines.push('  ' + pad('"' + name + '":', widest + 3) + ' "' + others[name] + '"' +
                 (i < sheetNames.length - 1 ? ',' : ''));
    });
    lines.push(' },');
  }
  lines.push(' "graphics": {');

  if (rows.length) {
    // Only the two leading fields are padded into columns. The nudge trails
    // off the end, where lining it up would cost more spaces than it repays.
    const width = function (prefix) {
      let most = 0;
      for (const row of rows) {
        for (const cell of row.cells.slice(0, 3)) {
          if (cell.startsWith(prefix) && cell.length > most) most = cell.length;
        }
      }
      return most;
    };
    const columns = { '"sprite"': width('"sprite"'), '"size"': width('"size"') };
    let widest = 0;
    for (const row of rows) {
      if (row.name.length > widest) widest = row.name.length;
    }

    rows.forEach(function (row, i) {
      const cells = row.cells.slice();
      for (let j = 0; j < Math.min(3, cells.length); j++) {
        for (const prefix of Object.keys(columns)) {
          if (cells[j].startsWith(prefix)) cells[j] = pad(cells[j], columns[prefix]);
        }
      }
      lines.push('  ' + pad('"' + row.name + '":', widest + 3) +
                 ' { ' + cells.join(', ') + ' }' +
                 (i < rows.length - 1 ? ',' : ''));
    });
  }

  lines.push(' }', '}');
  const text = lines.join('\n') + '\n';
  return eol === '\r\n' ? text.replace(/\n/g, '\r\n') : text;
}

// Left-justified in a field, which is what %-*s does on the Python side.
function pad(text, width) {
  return text.length >= width ? text : text + ' '.repeat(width - text.length);
}

function gameOf(said) {
  return (said && said.game) || '';
}

// How wide the table is: one past the highest number it names. The game's own
// was wider -- 256 for Knight Lore, of which it uses 186 -- but nothing reads
// past the last graphic that draws something.
function countOf(graphics) {
  let highest = -1;
  for (const number of graphicTable(graphics).keys()) {
    if (number > highest) highest = number;
  }
  return highest + 1;
}

// graphic number -> the sprite it names, for the numbers that draw something.
// A graphic can carry a nudge and no sprite; Knight Lore's 1 does.
function spriteOf(graphics) {
  const out = new Map();
  for (const [number, entry] of graphicTable(graphics)) {
    if (typeof entry.sprite === 'string' && entry.sprite) {
      out.set(number, entry.sprite);
    }
  }
  return out;
}

// ...and the nudge, which is the other half of the same entry.
function nudgeOf(graphics, graphic) {
  const entry = graphicTable(graphics).get(graphic);
  if (!entry || (entry.x === undefined && entry.y === undefined)) return null;
  return {
    x: entry.x || 0,
    y: entry.y || 0,
    mirrored: entry.mirrored || null,
    note: entry.note || null
  };
}

// sprite name -> every graphic number that names it, in order. This is the
// sharing, which the file states only by repeating a name.
function sharedBy(graphics) {
  const out = new Map();
  const table = spriteOf(graphics);
  for (const graphic of Array.from(table.keys()).sort((a, b) => a - b)) {
    const sprite = table.get(graphic);
    if (!out.has(sprite)) out.set(sprite, []);
    out.get(sprite).push(graphic);
  }
  return out;
}

// Every sprite the sheets hold, for the picker: what it is called, its group,
// the sheet it is on ('' for the game's own) and the rectangle it comes out of.
function sheetSprites(sheet, others) {
  return allSprites(sheet, others).map(function (sprite) {
    return {
      name: sprite.name,
      group: sprite.group,
      sheet: sprite.sheet,
      rect: { x: sprite.x, y: sprite.y, w: sprite.w, h: sprite.h }
    };
  });
}

// Whether the engine can draw a frame this size as one sprite: a blit is a
// routine for each width from two bytes to five, and redraw.s repaints 64 rows
// at most. examples/filmation/scripts/sheet.py stops the build on one that
// cannot; this is so the picker can say so first.
const NARROWEST = 16;
const WIDEST = 40;
const TALLEST = 64;

function fitsOneSprite(rect) {
  return !!rect && rect.w >= NARROWEST && rect.w <= WIDEST && rect.h >= 1 &&
    rect.h <= TALLEST;
}

// One row a graphic number, which is what the page lays out. Every number up
// to the last one the table names gets a row, including any it skips: an empty
// row is where a new graphic can go.
function rows(graphics, sheet, others) {
  const table = spriteOf(graphics);
  const shares = sharedBy(graphics);
  const known = spritesByName(sheet, others);
  // What each number is CALLED, which is the key it sits under in the file and
  // what rooms.json refers to it by.
  const named = new Map();
  const fixed = new Set();
  for (const [number, said] of graphicTable(graphics)) {
    named.set(number, said.name);
    if (said.fixed) fixed.add(number);
  }
  const out = [];
  for (let graphic = 0; graphic < countOf(graphics); graphic++) {
    const name = table.has(graphic) ? table.get(graphic) : null;
    const sprite = name === null ? null : known.get(name) || null;
    const also = name === null ? [] : (shares.get(name) || [])
      .filter(function (n) { return n !== graphic; });
    out.push({
      graphic: graphic,
      name: named.get(graphic) || null,
      sprite: name,
      nudge: nudgeOf(graphics, graphic),
      group: sprite ? sprite.group : null,
      sheet: sprite ? sprite.sheet : null,
      rect: sprite
        ? { x: sprite.x, y: sprite.y, w: sprite.w, h: sprite.h } : null,
      // Names a sprite the sheet has not got. The file is then pointing at
      // something that does not exist, which the page says rather than drawing
      // a blank that reads as an unused number.
      dangling: name !== null && !sprite,
      // The game's code knows it by this number, so it cannot be moved.
      fixed: fixed.has(graphic),
      sharedWith: also
    });
  }
  return out;
}

// --- editing --------------------------------------------------------------

// Point one graphic number at a different sprite, or at none.
//
// A copy rather than a change in place: the host writes whole documents and
// lets the editor's undo do the rest, so nothing here may mutate what it was
// given.
//
// The NUDGE is left alone either way, including when the sprite is taken away.
// It was harvested by adj.py from a RUNNING game and cannot be got back any
// other way, so nothing here throws one out on the strength of a click; an
// entry with a nudge and no sprite is a shape the file already has.
function setSprite(graphics, graphic, sprite) {
  const next = JSON.parse(JSON.stringify(graphics));
  if (!next.graphics) next.graphics = {};

  let key = keyOf(next, graphic);
  if (key === null) {
    // A number the table does not use yet: picking a sprite for it is how a
    // graphic is added. It is named after the sprite, the way the table's
    // first names were seeded -- with the sheet's separator made a dot, since
    // a graphic's name is a plain dotted one -- and the number goes on the
    // end only if that name is taken.
    if (sprite === null || sprite === undefined) return next;
    key = String(sprite).split(SHEET_SEPARATOR).join('.');
    if (Object.prototype.hasOwnProperty.call(next.graphics, key)) key += '.g' + graphic;
    next.graphics[key] = { number: graphic, sprite: sprite };
    return next;
  }

  const entry = next.graphics[key];
  if (sprite === null || sprite === undefined) delete entry.sprite;
  else entry.sprite = sprite;

  // The NAME is left alone, even when the sprite goes. It is what rooms.json
  // refers to the graphic by, so re-pointing a graphic at a different bitmap
  // must not rename it and leave every castle that places it dangling.
  return next;
}

// The file is keyed by NAME; the edits are asked in the game's numbers,
// because that is what a tile in the map is. The key that holds a number, or
// null if none does.
function keyOf(graphics, graphic) {
  const table = (graphics && graphics.graphics) || {};
  for (const name of Object.keys(table)) {
    if (table[name] && table[name].number === graphic) return name;
  }
  return null;
}

// Change a graphic's nudge: the plain one, or with `mirrored` the one it is
// drawn with when mirrored. A null mirrored nudge takes that one away, and the
// graphic is then drawn mirrored with its plain nudge, which is what most are.
//
// The harvested nudges are what make the original's pictures line up, and
// this is how one is changed on purpose -- with the picture to judge it by,
// and the editor's undo to bring the old one back. A number the table has not
// got is left alone: a nudge belongs to a graphic, and Add is what makes one.
function setNudge(graphics, graphic, nudge, mirrored) {
  const next = JSON.parse(JSON.stringify(graphics));
  const key = keyOf(next, graphic);
  if (key === null) return next;
  const entry = next.graphics[key];
  if (mirrored) {
    if (nudge) entry.mirrored = { x: nudge.x, y: nudge.y };
    else delete entry.mirrored;
  } else {
    // A zero nudge is no nudge, which is how the file says it.
    if (nudge && nudge.x) entry.x = nudge.x;
    else delete entry.x;
    if (nudge && nudge.y) entry.y = nudge.y;
    else delete entry.y;
  }
  return next;
}

// The numbers a graphic can never be: 0 ends a template and 1 is a piece
// something else draws, and a template names its graphic by the low byte, so
// 256 and 257 read as those two.
const NEVER_NUMBERS = [0, 1, 256, 257];

// How many graphic numbers a game has: `count`, its GRAPHIC_COUNT, when the
// host could find it (sheet_files.js), and otherwise worked out from the
// table -- 512 once it reaches past 256, which only a game built for 512 may,
// and 256 if not. The table alone cannot tell a game built for 512 that uses
// none past 255 from one built for 256.
function numberLimit(graphics, count) {
  if (count) return count > 256 ? 512 : 256;
  return countOf(graphics) > 256 ? 512 : 256;
}

// Whether the game's code knows a graphic by its number. See "fixed" in
// schemas/graphics.schema.json.
function isFixed(graphics, graphic) {
  const entry = graphicTable(graphics).get(graphic);
  return !!(entry && entry.fixed);
}

// Why a graphic cannot be moved to a number, or null if it can.
function whyNotMove(graphics, from, to, count) {
  const table = graphicTable(graphics);
  if (!table.has(from)) return 'graphic ' + from + ' is not in the table';
  if (from === to) return 'that is where it is';
  const limit = numberLimit(graphics, count);
  if (!Number.isInteger(to) || to < 0 || to >= limit) {
    return to + ' is past the ' + limit + ' numbers this game has';
  }
  if (NEVER_NUMBERS.indexOf(to) >= 0) return to + ' is never a graphic';
  if (table.get(from).fixed) return 'the game\'s code knows graphic ' + from + ' by its number';
  if (table.has(to) && table.get(to).fixed) {
    return 'the game\'s code knows graphic ' + to + ' by its number';
  }
  return null;
}

// Move a graphic to another number: onto an unused one it simply moves, and
// onto a used one the two swap. Nothing else is renumbered.
//
// Only the numbers change. The names stay -- rooms.json places a graphic by
// its name and the GFX_ label is made from it, so both follow the graphic to
// its new number, and the room data is rebuilt from them. That is also why a
// graphic the code knows by its number cannot move: nothing would follow it
// there. Throws, with the reason, when the move is not allowed.
function moveGraphic(graphics, from, to, count) {
  const why = whyNotMove(graphics, from, to, count);
  if (why) throw new Error(why);
  const next = JSON.parse(JSON.stringify(graphics));
  const moving = keyOf(next, from);
  const there = keyOf(next, to);
  next.graphics[moving].number = to;
  if (there !== null) next.graphics[there].number = from;
  return next;
}

// Give a graphic a box, or a different one: half-widths along U and V and a
// height, stored unmirrored. It is what every template placing the graphic is
// sorted and collided by, so it changes the rooms as well as the picture.
// A null box takes it away, which only a graphic no template places can
// spare -- graphics.py stops the build on any other.
function setBox(graphics, graphic, box) {
  const next = JSON.parse(JSON.stringify(graphics));
  const key = keyOf(next, graphic);
  if (key === null) return next;
  if (box) next.graphics[key].size = { u: box.u, v: box.v, z: box.z };
  else delete next.graphics[key].size;
  return next;
}

// --- the box and the nudge, for drawing -----------------------------------
//
// The nudge editor's picture: one graphic stood on the floor, its box drawn
// round where it stands and its sprite where the nudge puts it. Worked out
// here, in screen pixels relative to the point it stands on, so that the page
// only strokes and blits, and the arithmetic can be tested without a canvas.

// The box a graphic is drawn in: its own, or -- for a number that has none,
// the second frame of an animation, say -- the box of the first other number
// drawing the same sprite, and which number that was. Null if neither.
function boxFor(graphics, graphic) {
  const table = graphicTable(graphics);
  const entry = table.get(graphic);
  if (!entry) return null;
  if (entry.size) return { box: boxCopy(entry.size), from: graphic };
  if (!entry.sprite) return null;
  const numbers = Array.from(table.keys()).sort(function (a, b) { return a - b; });
  for (const number of numbers) {
    const other = table.get(number);
    if (number !== graphic && other.sprite === entry.sprite && other.size) {
      return { box: boxCopy(other.size), from: number };
    }
  }
  return null;
}

function boxCopy(box) {
  return { u: box.u, v: box.v, z: box.z };
}

// How far a nudge and a box can go. Each half of a nudge is a signed byte,
// except that a game of more than 256 graphic numbers keeps bit 8 of the
// graphic in bit 0 of ADJ_Y and the y nudge doubled above it -- see OBJ.ADJ_Y
// -- so y has seven bits; sprite_source.py adds any blank rows it trims off a
// sprite to y before it doubles it, and says so if that is then too far. A
// template there carries the same bit in bit 7 of its height, so the height
// has seven bits too. A half-width past 127 would reach past the world.
// `count` is the game's GRAPHIC_COUNT, as numberLimit takes it.
function editLimits(graphics, count) {
  const nine = numberLimit(graphics, count) > 256;
  return { x: { min: -128, max: 127 },
           y: nine ? { min: -64, max: 63 } : { min: -128, max: 127 },
           u: { min: 0, max: 127 },
           v: { min: 0, max: 127 },
           z: { min: 0, max: nine ? 127 : 255 } };
}

// A first box for a graphic that has none, from the size of its frame. A box
// of half-widths U and V is 2(U + V) pixels across on the screen and its
// ground diamond U + V rows deep, so a square one as wide as the sprite has
// half-widths of a quarter of it, and is as tall as what is left of the
// sprite above the diamond. Something to drag the sprite against and correct,
// not a measurement.
function guessBox(size) {
  const half = Math.max(1, Math.floor(size.w / 4));
  return { u: half, v: half, z: Math.max(0, size.h - 2 * half) };
}

// The plain nudge, reflected: what puts a mirrored sprite where the plain one
// would be, mirror image for mirror image. object_place takes the left
// column, and flipping a sprite W wide about the point it stands on moves its
// left column from x to -(x + W); the row does not change. Knight Lore's own
// doorways agree on the column and want a row lower mirrored, so this is a
// place to start from, not the answer.
function reflectedNudge(nudge, width) {
  return { x: -((nudge ? nudge.x : 0) + width), y: nudge ? nudge.y : 0 };
}

// Where the picture puts a graphic: the middle of a room, where nothing
// wraps, at the height of nothing in particular -- only the differences from
// this point are drawn.
const STAGE_UV = 128;

// Everything the nudge editor draws, relative to the point the graphic stands
// on -- its (U, V, Z), the middle of its box along the ground and the bottom
// of it -- in screen pixels, y down the screen.
//
//   nudge     { x, y }, the one it is drawn with this way round
//   box       { u, v, z } as graphics.json stores it, or null
//   size      { w, h } of the sprite's frame
//   mirrored  whether it is drawn mirrored, which swaps the box's U and V
//
// object_place puts the sprite's left column at the point's x plus the x
// nudge, and its base -- the row just past its bottom -- at the point's row
// less the y nudge, so a positive y raises it. The box's corners go through
// floorPoint, the projection the room designer draws with.
//
// Corner i has U at its high end when bit 0 is set, V when bit 1 is, and Z
// when bit 2 is; an edge joins two that differ in one bit. Corner 2 -- U low,
// V high, on the ground -- is the one furthest from the viewer, so the three
// edges that meet there are behind the box.
const FAR_CORNER = 2;

function boxView(nudge, box, size, mirrored) {
  const out = { corners: [], edges: [], floor: [], top: [], sprite: null, bounds: null };
  const here = floorPoint(STAGE_UV, STAGE_UV, 0);
  const at = function (u, v, z) {
    const p = floorPoint(STAGE_UV + u, STAGE_UV + v, z);
    return { x: p.x - here.x, y: p.y - here.y };
  };

  if (box) {
    const su = mirrored ? box.v : box.u;
    const sv = mirrored ? box.u : box.v;
    for (let i = 0; i < 8; i++) {
      out.corners.push(at(i & 1 ? su : -su, i & 2 ? sv : -sv, i & 4 ? box.z : 0));
    }
    for (let i = 0; i < 8; i++) {
      for (const bit of [1, 2, 4]) {
        if (i & bit) continue;
        out.edges.push({ from: i, to: i | bit,
                         hidden: i === FAR_CORNER || (i | bit) === FAR_CORNER });
      }
    }
    // Round each face, so either can be filled as it stands.
    for (const i of [0, 1, 3, 2]) {
      out.floor.push(out.corners[i]);
      out.top.push(out.corners[i + 4]);
    }
  }

  const x = nudge ? nudge.x : 0;
  const y = nudge ? nudge.y : 0;
  out.sprite = { x: x, y: -y - size.h, w: size.w, h: size.h, flipped: !!mirrored };

  let minX = 0;
  let minY = 0;
  let maxX = 0;
  let maxY = 0;
  const take = function (px, py) {
    minX = Math.min(minX, px);
    minY = Math.min(minY, py);
    maxX = Math.max(maxX, px);
    maxY = Math.max(maxY, py);
  };
  for (const p of out.corners) take(p.x, p.y);
  take(out.sprite.x, out.sprite.y);
  take(out.sprite.x + out.sprite.w, out.sprite.y + out.sprite.h);
  out.bounds = { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
  return out;
}

// --- checking -------------------------------------------------------------

// What is wrong with a table, for the page to show rather than to stop on.
// None of these is fatal to the build; a sprite the sheet has not got is the
// one that would actually break a game, because sprite_table would then point
// at nothing.
function checkMap(graphics, sheet, others) {
  const problems = [];
  const known = spritesByName(sheet, others);

  for (const [number, entry] of graphicTable(graphics)) {
    const sprite = entry.sprite;
    if (sprite === undefined) {
      continue;             // a nudge and no sprite, which is a real shape
    }
    const called = entry.name || ('graphic ' + number);
    if (typeof sprite === 'number') {
      problems.push(called + ' names sprite ' + sprite +
                    ', a number. Sprites are named now.');
    } else if (typeof sprite !== 'string') {
      problems.push(called + ' names ' + JSON.stringify(sprite) +
                    ', which is not a sprite.');
    } else if (known.size && !known.has(sprite)) {
      problems.push(called + ' names the sprite "' + sprite +
                    '", which the sheet has not got.');
    }
  }

  // Only the game's own sheet: the others are a catalogue to pick from, and
  // most of what is on them is meant to stay out of the game.
  const own = spriteList(sheet);
  if (own.length) {
    const used = new Set(spriteOf(graphics).values());
    const orphans = own.map(function (sprite) { return sprite.name; })
      .filter(function (name) { return !used.has(name); });
    if (orphans.length) {
      problems.push(orphans.length + ' sprite' + (orphans.length === 1 ? '' : 's') +
                    ' no graphic number draws: ' + orphans.slice(0, 6).join(', ') +
                    (orphans.length > 6 ? ', ...' : '') + '.');
    }
  }
  return problems;
}

// A one-line summary for the page's header: what the file amounts to.
function summary(graphics, sheet, others) {
  const table = spriteOf(graphics);
  const fromOthers = new Set(Array.from(table.values()).filter(function (name) {
    return name.indexOf(SHEET_SEPARATOR) >= 0;
  }));
  return {
    count: countOf(graphics),
    used: table.size,
    sprites: new Set(table.values()).size,
    onSheet: spriteList(sheet).length,
    // The other sheets: how many there are, and how many of their sprites
    // the table draws.
    sheets: Object.keys(others || {}).length,
    fromSheets: fromOthers.size,
    shared: Array.from(sharedBy(graphics).values())
      .filter(function (list) { return list.length > 1; }).length
  };
}

if (typeof module !== 'undefined') {
  module.exports = {
    NO_SPRITE,
    parseMap, serializeMap, gameOf, countOf,
    spriteOf, nudgeOf, sharedBy, sheetSprites, fitsOneSprite, rows,
    setSprite, setNudge, setBox, checkMap, summary,
    NEVER_NUMBERS, numberLimit, isFixed, whyNotMove, moveGraphic,
    boxFor, editLimits, guessBox, reflectedNudge, boxView, FAR_CORNER
  };
}
