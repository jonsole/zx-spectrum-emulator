// One open sprite sheet: the description, the picture it names, and the
// edits made to them since it was opened.
//
// The sprite sheet editor's host keeps one of these a document. It is the
// whole of what the editor knows about the files -- finding the picture,
// reading it, painting it, putting a stroke back, writing it out -- so it is
// here, with no vscode API, where the tests can reach it:
//   node examples/filmation/vscode/tests/sprite_sheet_document_test.js

'use strict';

const fs = require('fs');
const path = require('path');
const png = require('./png_codec');
const model = require('./sprite_sheet_model');
const sheetModel = require('./sheet_model');
const layout = require('./game_layout');

class SheetFile {
  // Open a description and the picture it names. Throws, with the reason in
  // words, if either cannot be read.
  static load(jsonPath) {
    const text = fs.readFileSync(jsonPath, 'utf8');
    let sheet;
    try {
      // In the file's own order: see parseSheet.
      sheet = model.parseSheet(text);
    } catch (err) {
      throw new Error('it is not JSON: ' + err.message);
    }
    if (!sheet || typeof sheet !== 'object' || !sheet.group) {
      throw new Error('it has no "group" tree, so it is not a sprite sheet description');
    }
    const here = path.dirname(jsonPath);
    const named = sheetModel.formatOf(sheet).file;
    const pngPath = layout.withinGame(here, named);
    if (!pngPath) throw new Error('it names its picture as ' + named + ', outside the game');
    if (!fs.existsSync(pngPath)) {
      throw new Error('its picture, ' + path.relative(here, pngPath) + ', is not there -- ' +
                      'a sheet converted from your own copy of a game is never carried, ' +
                      'so convert it again');
    }
    const bytes = fs.readFileSync(pngPath);
    return new SheetFile(jsonPath, text, sheet, pngPath, png.decode(bytes), bytes);
  }

  constructor(jsonPath, text, sheet, pngPath, picture, bytes) {
    this.jsonPath = jsonPath;
    this.text = text;
    this.eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    this.sheet = sheet;
    this.pngPath = pngPath;
    this.picture = picture;
    this.colours = model.coloursOf(sheet);
    // The file as it was last read or written, so a change to it on the disk
    // can be told from this editor's own Save coming back.
    this.onDisk = bytes;
    this.edited = false;
  }

  // A stroke from the page, checked against this side's own pixels -- the
  // page's are a copy -- and applied. Each change is { x, y, to }; a pixel
  // outside every sprite, or already that colour, is dropped. Returns what
  // was done, as the changes with their `from`, for undo; empty if nothing.
  paint(changes) {
    const done = [];
    const rects = model.allSpritesOf(model.sheetTree(this.sheet)).map((s) => s.rect);
    for (const c of changes) {
      if (model.PAINTS.indexOf(c.to) < 0) continue;
      if (!rects.some((r) => model.inside(r, c.x, c.y))) continue;
      const from = model.colourAt(this.picture, this.colours, c.x, c.y);
      if (from === c.to) continue;
      done.push({ x: c.x, y: c.y, from: from, to: c.to });
    }
    model.applyChanges(this.picture, this.colours, done, false);
    if (done.length) this.edited = true;
    return done;
  }

  // Undo and redo: the same stroke, one way or the other.
  apply(done, backwards) {
    model.applyChanges(this.picture, this.colours, done, backwards);
    this.edited = true;
  }

  // A change to the layout -- a sprite resized or moved, the sheet tidied --
  // as the new picture and the new description: what differs is kept, both
  // ways round, and the new pair becomes the sheet. Returns the record that
  // undoes and redoes it.
  layout(picture, sheet) {
    const record = {
      diff: model.diffPictures(this.picture, picture),
      before: JSON.parse(JSON.stringify(this.sheet)),
      after: JSON.parse(JSON.stringify(sheet))
    };
    this.picture = picture;
    this.sheet = sheet;
    this.edited = true;
    return record;
  }

  // ...and one way or the other.
  relayout(record, backwards) {
    this.picture = model.applyDiff(this.picture, record.diff, backwards);
    this.sheet = JSON.parse(JSON.stringify(backwards ? record.before : record.after));
    this.edited = true;
  }

  // The description as the file would have it.
  description() {
    return model.formatSheet(this.sheet, this.eol);
  }

  // The picture as a PNG: the file itself while nothing has been painted, so
  // opening a sheet costs no encoding.
  pngBytes() {
    return this.edited ? png.encode(this.picture) : this.onDisk;
  }

  // Both files: the picture, and the description if a layout change moved
  // anything in it -- written in sheet.py's layout, so the change diffs as
  // the lines it touched.
  save() {
    const bytes = png.encode(this.picture);
    fs.writeFileSync(this.pngPath, bytes);
    this.onDisk = bytes;
    const text = this.description();
    if (text !== this.text) {
      fs.writeFileSync(this.jsonPath, text);
      this.text = text;
    }
    this.edited = false;
  }

  // Back to what the disk holds.
  revert() {
    const fresh = SheetFile.load(this.jsonPath);
    Object.assign(this, fresh);
  }

  // Whether the picture on the disk is other than this editor last read or
  // wrote -- a paint program saving over it, say.
  changedOnDisk() {
    try {
      return !fs.readFileSync(this.pngPath).equals(this.onDisk);
    } catch (err) {
      return false;
    }
  }
}

// How graphics.json names this sheet's sprites, and which graphics draw each:
// { graphics, prefix }, or null if there is no graphics.json that lists it.
// The game's own sheet is graphics.json's "sprites"; one of the others is
// under "sheets", and its sprites are named with that key and a colon.
function graphicsFor(jsonPath) {
  const here = path.dirname(jsonPath);
  const meta = layout.gameDirAbove(here) === here ? here
    : path.join(layout.gameDirAbove(here), layout.METADATA);
  const file = path.join(meta, 'graphics.json');
  let graphics;
  try {
    graphics = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return null;
  }
  const same = (named) => typeof named === 'string' &&
    path.resolve(meta, named).toLowerCase() === path.resolve(jsonPath).toLowerCase();
  if (same(graphics.sprites || 'sprites.json')) return { graphics: graphics, prefix: '' };
  const sheets = sheetModel.sheetsOf(graphics);
  for (const name of Object.keys(sheets)) {
    if (same(sheets[name])) return { graphics: graphics, prefix: name + sheetModel.SHEET_SEPARATOR };
  }
  return null;
}

module.exports = { SheetFile, graphicsFor };
