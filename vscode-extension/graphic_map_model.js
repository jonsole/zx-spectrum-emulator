// What a Filmation graphic table is, and the edits you can make to one.
//
// examples/filmation/<game>/graphics.json is the table the game indexes by:
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
// (node vscode-extension/tests/graphic_map_model_test.js). The page gets it
// inlined as source, which is why nothing here may use require() and why the
// export at the bottom is guarded.

'use strict';

// sheet_model.js is the one place that knows the two files' shapes -- see the
// note in room_render.js about why it is pulled in the way it is.
if (typeof require !== 'undefined' && typeof module !== 'undefined') {
  // eslint-disable-next-line no-var, vars-on-top
  var { spriteList, spritesByName, graphicTable, graphicsByName } =
    require('./sheet_model');
}

// How the packed form said "this graphic has no bitmap". Nothing writes it any
// more -- a graphic with no sprite simply has no `sprite` -- and it is here so
// that a file converted by hand from the old .bin is caught rather than
// quietly believed.
const NO_SPRITE = 255;

function parseMap(text) {
  return JSON.parse(text);
}

// ...and back out, laid out the way examples/filmation/graphics.py writes it:
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
    rows.push({ name: key, cells: cells });
  }

  const sheet = (said && said.sprites) || 'sprites.json';
  const lines = ['{', ' "sprites": "' + sheet + '",', ' "graphics": {'];

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

// Every sprite the sheet holds, for the picker: what it is called, its group,
// and the rectangle it comes out of.
function sheetSprites(sheet) {
  return spriteList(sheet).map(function (sprite) {
    return {
      name: sprite.name,
      group: sprite.group,
      rect: { x: sprite.x, y: sprite.y, w: sprite.w, h: sprite.h }
    };
  });
}

// One row a graphic number, which is what the page lays out. Every number up
// to the last one the table names gets a row, including any it skips: an empty
// row is where a new graphic can go.
function rows(graphics, sheet) {
  const table = spriteOf(graphics);
  const shares = sharedBy(graphics);
  const known = spritesByName(sheet);
  // What each number is CALLED, which is the key it sits under in the file and
  // what rooms.json refers to it by.
  const named = new Map();
  for (const [number, said] of graphicTable(graphics)) named.set(number, said.name);
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
      rect: sprite
        ? { x: sprite.x, y: sprite.y, w: sprite.w, h: sprite.h } : null,
      // Names a sprite the sheet has not got. The file is then pointing at
      // something that does not exist, which the page says rather than drawing
      // a blank that reads as an unused number.
      dangling: name !== null && !sprite,
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

  // The file is keyed by NAME; this is asked in the game's numbers, because
  // that is what a tile in the map is. Find the key that holds the number.
  let key = null;
  for (const name of Object.keys(next.graphics)) {
    if (next.graphics[name] && next.graphics[name].number === graphic) {
      key = name;
      break;
    }
  }
  if (key === null) return next;        // no such graphic: nothing to re-point

  const entry = next.graphics[key];
  if (sprite === null || sprite === undefined) delete entry.sprite;
  else entry.sprite = sprite;

  // The NAME is left alone, even when the sprite goes. It is what rooms.json
  // refers to the graphic by, so re-pointing a graphic at a different bitmap
  // must not rename it and leave every castle that places it dangling.
  return next;
}

// --- checking -------------------------------------------------------------

// What is wrong with a table, for the page to show rather than to stop on.
// None of these is fatal to the build; a sprite the sheet has not got is the
// one that would actually break a game, because sprite_table would then point
// at nothing.
function checkMap(graphics, sheet) {
  const problems = [];
  const known = spritesByName(sheet);

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

  if (known.size) {
    const used = new Set(spriteOf(graphics).values());
    const orphans = Array.from(known.keys()).filter(function (name) {
      return !used.has(name);
    });
    if (orphans.length) {
      problems.push(orphans.length + ' sprite' + (orphans.length === 1 ? '' : 's') +
                    ' no graphic number draws: ' + orphans.slice(0, 6).join(', ') +
                    (orphans.length > 6 ? ', ...' : '') + '.');
    }
  }
  return problems;
}

// A one-line summary for the page's header: what the file amounts to.
function summary(graphics, sheet) {
  const table = spriteOf(graphics);
  return {
    count: countOf(graphics),
    used: table.size,
    sprites: new Set(table.values()).size,
    onSheet: spriteList(sheet).length,
    shared: Array.from(sharedBy(graphics).values())
      .filter(function (list) { return list.length > 1; }).length
  };
}

if (typeof module !== 'undefined') {
  module.exports = {
    NO_SPRITE,
    parseMap, serializeMap, gameOf, countOf,
    spriteOf, nudgeOf, sharedBy, sheetSprites, rows,
    setSprite, checkMap, summary
  };
}
