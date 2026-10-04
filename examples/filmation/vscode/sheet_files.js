// Finding the files a page draws from, beside a game's graphics.json: the
// other sheets it lists and their pictures, and how many graphic numbers the
// game is built with.
//
// The graphic map and the templates editor both want these, found the same
// way. No vscode API, so the tests can find them as the hosts do; the hosts
// pass in how to turn a picture into something a webview can show.
//
//   node examples/filmation/vscode/tests/graphic_map_page_test.js

'use strict';

const fs = require('fs');
const path = require('path');
const sheetModel = require('./sheet_model');
const layout = require('./game_layout');

function readIfThere(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return null;
  }
}

// The other sheets graphics.json lists -- Lightkeep's Melkhior ones -- each a
// description and a picture. `here` is graphics.json's folder, and `picture`
// turns a PNG's path into what the page is given for it (a data: URI, in the
// editor). One whose picture is not there yet still lists its sprites,
// without a picture: it was converted from someone's own copy of a game, and
// this tree has not had that done. One whose description is not there at all
// is left out.
function otherSheets(graphics, here, picture) {
  const others = {};
  const otherPngs = {};
  const listed = sheetModel.sheetsOf(graphics);
  for (const name of Object.keys(listed)) {
    const file = layout.within(here, listed[name]);
    const text = file && readIfThere(file);
    if (!text) continue;
    try {
      others[name] = JSON.parse(text);
    } catch (err) {
      continue;
    }
    // Relative to the sheet, which is a folder further down than the game's
    // metadata/ -- so bounded by graphics.json's folder, which knows the game.
    const png = layout.within(here, path.relative(here, path.resolve(
      path.dirname(file), sheetModel.formatOf(others[name]).file)));
    otherPngs[name] = png && picture ? picture(png) : png || null;
  }
  return { others: others, otherPngs: otherPngs };
}

// How many graphic numbers the game is BUILT with: GRAPHIC_COUNT in its
// scripts/sprite_sheet.py, which sprite_source.py writes into the generated
// sources and which decides whether the engine keeps bit 8 of a graphic in
// ADJ_Y. The table alone cannot say -- Lightkeep is built for 512 and may use
// none past 255 -- and that decides how far a y nudge may go. Null if the game
// does not say.
const COUNT_LINE = /^GRAPHIC_COUNT\s*=\s*(\d+)\s*$/m;

function graphicCountOf(gameDir) {
  const text = readIfThere(path.join(gameDir, 'scripts', 'sprite_sheet.py'));
  const found = text && COUNT_LINE.exec(text);
  return found ? Number(found[1]) : null;
}

module.exports = { otherSheets, graphicCountOf };
