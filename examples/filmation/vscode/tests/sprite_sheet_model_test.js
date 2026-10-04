// Tests for sprite_sheet_model.js and sprite_sheet_document.js: what a sheet
// is, what a stroke does to it, what the build will say about a sprite, and
// a sheet opened, painted, undone, saved and read back.
//
//   node examples/filmation/vscode/tests/sprite_sheet_model_test.js
//
// The small tests use a sheet drawn here by hand, so the right answers are
// worked out from the picture rather than read back out of the model.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const m = require('../sprite_sheet_model');
const png = require('../png_codec');
const { SheetFile, graphicsFor } = require('../sprite_sheet_document');

const FILMATION = path.join(__dirname, '..', '..');

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

// A description with two groups, one inside the other, and three sprites.
function toySheet() {
  return {
    sheet: { file: '../art/sprites.png' },
    group: {
      knight: {
        sprites: { 1: { x: 1, y: 1, w: 8, h: 4 } },
        group: { legs: { sprites: { 1: { x: 12, y: 1, w: 8, h: 4, trim: 2 } } } }
      },
      door: { sprites: { arch: { x: 1, y: 8, w: 16, h: 3 } } }
    }
  };
}

// The picture for it, 24 by 12: every pixel clear, a magenta frame round
// each sprite, and the knight's first sprite paper but for an ink column.
function toyPicture() {
  const width = 24;
  const height = 12;
  const picture = { width: width, height: height, rgba: new Uint8Array(width * height * 4) };
  const colours = m.coloursOf(toySheet());
  for (const sprite of m.allSpritesOf(m.sheetTree(toySheet()))) {
    for (const p of m.frameOf(sprite.rect)) m.setColour(picture, colours, p.x, p.y, 'border');
  }
  for (let y = 1; y < 5; y++) {
    for (let x = 1; x < 9; x++) m.setColour(picture, colours, x, y, x === 4 ? 'ink' : 'paper');
  }
  return picture;
}

const COLOURS = m.coloursOf(toySheet());

test('the tree keeps the file\'s groups and order, and each sprite its path', () => {
  const tree = m.sheetTree(toySheet());
  assert.deepStrictEqual(tree.groups.map((g) => g.path), ['knight', 'door']);
  assert.deepStrictEqual(tree.groups[0].groups.map((g) => g.path), ['knight.legs']);
  assert.deepStrictEqual(m.allSpritesOf(tree).map((s) => s.path),
                         ['knight.1', 'knight.legs.1', 'door.arch']);
  assert.strictEqual(m.allSpritesOf(tree)[1].trim, 2);
});

test('the colours default to sheet.py\'s, and a description can say its own', () => {
  assert.deepStrictEqual(COLOURS.border, [255, 0, 255, 255]);
  const said = toySheet();
  said.sheet.colours = { ink: [0, 255, 0] };
  assert.deepStrictEqual(m.coloursOf(said).ink, [0, 255, 0, 255]);
});

test('a pixel\'s colour is what it means: see-through is transparent whatever its RGB', () => {
  const picture = toyPicture();
  assert.strictEqual(m.colourAt(picture, COLOURS, 4, 2), 'ink');
  assert.strictEqual(m.colourAt(picture, COLOURS, 5, 2), 'paper');
  assert.strictEqual(m.colourAt(picture, COLOURS, 0, 0), 'border');
  assert.strictEqual(m.colourAt(picture, COLOURS, 22, 11), 'transparent');
  picture.rgba.set([10, 20, 30, 255], (11 * 24 + 22) * 4);
  assert.strictEqual(m.colourAt(picture, COLOURS, 22, 11), null, 'a colour with no meaning');
});

test('paint stays inside the sprite, and leaves out what is already that colour', () => {
  const picture = toyPicture();
  const rect = { x: 1, y: 1, w: 8, h: 4 };
  // (0,1) is the frame, (4,2) is ink already, (2,2) twice is one pixel.
  const changes = m.paint(picture, COLOURS, rect,
    [{ x: 0, y: 1 }, { x: 4, y: 2 }, { x: 2, y: 2 }, { x: 2, y: 2 }, { x: 8, y: 4 }], 'ink');
  assert.deepStrictEqual(changes, [
    { x: 2, y: 2, from: 'paper', to: 'ink' },
    { x: 8, y: 4, from: 'paper', to: 'ink' }
  ]);
  assert.strictEqual(m.colourAt(picture, COLOURS, 2, 2), 'paper', 'paint only says; apply does');
  m.applyChanges(picture, COLOURS, changes, false);
  assert.strictEqual(m.colourAt(picture, COLOURS, 2, 2), 'ink');
  m.applyChanges(picture, COLOURS, changes, true);
  assert.strictEqual(m.colourAt(picture, COLOURS, 2, 2), 'paper', 'backwards is undo');
});

test('a press toggles ink and paper, puts the picked colour on a clear pixel, and Transparent rubs out', () => {
  for (const picked of ['ink', 'paper', 'stray']) {
    assert.strictEqual(m.strokeColour('ink', picked), 'paper', picked);
    assert.strictEqual(m.strokeColour('paper', picked), 'ink', picked);
    assert.strictEqual(m.strokeColour('transparent', picked), picked, picked);
    assert.strictEqual(m.strokeColour('stray', picked), picked, picked);
  }
  for (const under of ['ink', 'paper', 'transparent', 'stray']) {
    assert.strictEqual(m.strokeColour(under, 'transparent'), 'transparent', under);
  }
});

test('a fill takes the joined pixels of one colour, and stops at the ink column', () => {
  const picture = toyPicture();
  const rect = { x: 1, y: 1, w: 8, h: 4 };
  // The paper left of the ink column at x = 4 is x 1..3, four rows: twelve.
  const left = m.fill(picture, COLOURS, rect, 2, 3, 'transparent');
  assert.strictEqual(left.length, 12);
  assert.ok(left.every((c) => c.x >= 1 && c.x <= 3 && c.from === 'paper'));
  // The ink column itself: four pixels, one a row.
  assert.strictEqual(m.fill(picture, COLOURS, rect, 4, 1, 'paper').length, 4);
  // Filling with the colour already there changes nothing.
  assert.deepStrictEqual(m.fill(picture, COLOURS, rect, 2, 3, 'paper'), []);
});

test('the frame is the ring just outside the rectangle', () => {
  // 8 by 4: two rows of ten above and below, and two columns of four.
  const ring = m.frameOf({ x: 1, y: 1, w: 8, h: 4 });
  assert.strictEqual(ring.length, 2 * 10 + 2 * 4);
  assert.ok(ring.some((p) => p.x === 0 && p.y === 0));
  assert.ok(ring.some((p) => p.x === 9 && p.y === 5));
  assert.ok(!ring.some((p) => p.x === 1 && p.y === 1), 'a pixel of the sprite');
});

test('what the build will say: a whole frame and known colours say nothing', () => {
  const picture = toyPicture();
  const rect = { x: 1, y: 1, w: 8, h: 4 };
  assert.deepStrictEqual(m.spriteProblems(picture, COLOURS, rect, false), []);
  m.setColour(picture, COLOURS, 0, 2, 'ink');           // the frame
  m.setColour(picture, COLOURS, 3, 3, 'border');        // inside it
  const said = m.spriteProblems(picture, COLOURS, rect, false);
  assert.strictEqual(said.length, 2, said.join('; '));
  assert.ok(/1 pixel of its frame is not/.test(said[0]), said[0]);
  assert.ok(/1 pixel is a colour/.test(said[1]), said[1]);
});

test('...and, for another sheet\'s sprite, the engine\'s sizes', () => {
  const picture = toyPicture();
  // 8 wide is a byte too narrow for the engine's narrowest blit.
  const rect = { x: 1, y: 1, w: 8, h: 4 };
  assert.deepStrictEqual(m.spriteProblems(picture, COLOURS, rect, false), []);
  assert.ok(/16 to 40 wide/.test(m.spriteProblems(picture, COLOURS, rect, true).join()));
  assert.ok(/runs off/.test(m.spriteProblems(picture, COLOURS, { x: 0, y: 1, w: 8, h: 4 }, false)[0]));
});

test('which graphics draw a sprite, by how graphics.json names this sheet', () => {
  const graphics = { graphics: {
    'a': { number: 30, sprite: 'guard.1' },
    'b': { number: 150, sprite: 'guard.1' },
    'c': { number: 200, sprite: 'doors:DoorSide1.0' },
    'd': { number: 1 }
  } };
  const own = m.graphicsDrawing(graphics, '');
  assert.deepStrictEqual(own.get('guard.1'), [30, 150]);
  assert.strictEqual(own.has('doors:DoorSide1.0'), false, 'another sheet\'s sprite');
  assert.deepStrictEqual(m.graphicsDrawing(graphics, 'doors:').get('DoorSide1.0'), [200]);
});

// --- the description written back ------------------------------------------------

test('every real description comes back out of formatSheet byte for byte', () => {
  // sheet.py's format_sheet wrote them; the editor writes the same layout, so
  // a resize diffs as the one line it changed.
  const files = [];
  for (const game of fs.readdirSync(FILMATION)) {
    const meta = path.join(FILMATION, game, 'metadata');
    if (fs.existsSync(path.join(meta, 'sprites.json'))) files.push(path.join(meta, 'sprites.json'));
    const melkhior = path.join(meta, 'melkhior');
    if (fs.existsSync(melkhior)) {
      for (const f of fs.readdirSync(melkhior)) if (f.endsWith('.json')) files.push(path.join(melkhior, f));
    }
  }
  assert.ok(files.length >= 4);
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    const eol = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
    assert.strictEqual(m.formatSheet(m.parseSheet(text), eol), text, path.relative(FILMATION, file));
  }
});

test('the file\'s order is kept, even where a name looks like a number', () => {
  // JSON.parse would put "1" first; the build reads "2" first.
  const sheet = m.parseSheet('{ "group": { "g": { "sprites": { "2": { "x": 1, "y": 1, "w": 8, "h": 1 },' +
                             ' "1": { "x": 12, "y": 1, "w": 8, "h": 1 } } } } }');
  assert.deepStrictEqual(m.allSpritesOf(m.sheetTree(sheet)).map((s) => s.path), ['g.2', 'g.1']);
  assert.deepStrictEqual(m.allSpritesOf(m.sheetTree(JSON.parse(JSON.stringify(sheet))))
    .map((s) => s.path), ['g.2', 'g.1'], 'and survives being sent as JSON');
});

// --- sizes and places --------------------------------------------------------------

// A picture with room to grow: 40 by 20, the knight's sprite of the toy
// sheet alone at (1, 1), 8 by 4, paper with an ink column at x = 4.
function roomySheet() {
  return { sheet: { file: 'x.png' },
           group: { knight: { sprites: { 1: { x: 1, y: 1, w: 8, h: 4 } } } } };
}

function roomyPicture() {
  const picture = { width: 40, height: 20, rgba: new Uint8Array(40 * 20 * 4) };
  m.allSpritesOf(m.sheetTree(roomySheet())).forEach((s) => {
    for (const p of m.frameOf(s.rect)) m.setColour(picture, COLOURS, p.x, p.y, 'border');
  });
  for (let y = 1; y < 5; y++) {
    for (let x = 1; x < 9; x++) m.setColour(picture, COLOURS, x, y, x === 4 ? 'ink' : 'paper');
  }
  return picture;
}

test('a sprite grown on the right stays put, keeps its pixels, and gets a new frame', () => {
  const was = roomyPicture();
  const out = m.resizeSprite(was, COLOURS, roomySheet(), 'knight.1', { right: 8 });
  assert.deepStrictEqual(out.rect, { x: 1, y: 1, w: 16, h: 4 });
  assert.strictEqual(out.moved, false);
  assert.deepStrictEqual(m.spriteNode(out.sheet, 'knight.1').sprites['1'],
                         { x: 1, y: 1, w: 16, h: 4 });
  // The ink column is where it was; the new half is clear; the old frame's
  // right side, at x = 9, is now a clear pixel of the sprite.
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 2), 'ink');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 9, 2), 'transparent');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 16, 2), 'transparent');
  assert.deepStrictEqual(m.spriteProblems(out.picture, COLOURS, out.rect, false), []);
  assert.strictEqual(m.colourAt(was, COLOURS, 9, 2), 'border', 'the picture it was given changed');
});

test('a row taken off the top moves what is below it up the rectangle, not the screen', () => {
  // The rectangle starts a row lower; every pixel left is where it was on
  // the picture, so the art stands where it stood.
  const out = m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'knight.1', { top: -1 });
  assert.deepStrictEqual(out.rect, { x: 1, y: 2, w: 8, h: 3 });
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 2), 'ink');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 1), 'border', 'the new frame\'s top');
  assert.deepStrictEqual(m.spriteProblems(out.picture, COLOURS, out.rect, false), []);
});

test('a byte added on the left moves the rectangle left, if there is room', () => {
  // At x = 1 there is no room to the left -- the frame would be at -8 --
  // so it goes to the first place it fits: with the old one cleared away,
  // that is (1, 1) again, the pixels a byte further right in the rectangle.
  const out = m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'knight.1', { left: 8 });
  assert.strictEqual(out.moved, true);
  assert.deepStrictEqual(out.rect, { x: 1, y: 1, w: 16, h: 4 });
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 12, 2), 'ink', 'the ink column, a byte on');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 2), 'transparent');
});

test('a sprite with no room where it is goes to the first place that has some', () => {
  // The toy sheet: knight.1 at x 1-8, knight.legs.1 at 12-19, 24 wide. One
  // byte more on the right would run its frame into the legs' frame at 11,
  // and nowhere else on the 24 by 12 picture is clear: the door arch's frame
  // is its last row, 11. So the picture grows -- a clear row (12), the new
  // frame (13), the sprite from row 14, four rows, and its frame on 18.
  const out = m.resizeSprite(toyPicture(), COLOURS, toySheet(), 'knight.1', { right: 8 });
  assert.strictEqual(out.moved, true);
  assert.deepStrictEqual(out.rect, { x: 1, y: 14, w: 16, h: 4 });
  assert.strictEqual(out.picture.height, 19, 'the picture grew to hold it, frame and all');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 15), 'ink', 'its pixels came with it');
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 2), 'transparent', 'and left nothing behind');
  for (const s of m.allSpritesOf(m.sheetTree(out.sheet))) {
    assert.deepStrictEqual(m.spriteProblems(out.picture, COLOURS, s.rect, false), [], s.path);
  }
});

test('a resize the build could not read is refused, with the reason', () => {
  assert.throws(() => m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'knight.1', { right: 4 }),
                /whole bytes/);
  assert.throws(() => m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'knight.1', { right: -8 }),
                /at least a byte/);
  assert.throws(() => m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'knight.1', { top: -4 }),
                /at least a row/);
  assert.throws(() => m.resizeSprite(roomyPicture(), COLOURS, roomySheet(), 'nobody', { top: 1 }),
                /no sprite/);
});

test('tidy lays the sprites out in the tree\'s order, each group from a new row', () => {
  // knight.1 at (1, 1), 4 high, so the next group starts at 1 + 4 + 3 = 8;
  // knight.legs.1 there, 4 high, so the door group at 8 + 4 + 3 = 15.
  const out = m.tidySheet(toyPicture(), COLOURS, toySheet());
  const at = (p) => { const n = m.spriteNode(out.sheet, p); const b = n.sprites[n.key]; return [b.x, b.y]; };
  assert.deepStrictEqual(at('knight.1'), [1, 1]);
  assert.deepStrictEqual(at('knight.legs.1'), [1, 8]);
  assert.deepStrictEqual(at('door.arch'), [1, 15]);
  // The arch is 3 high from row 15, its frame on row 18: the picture ends
  // a clear row after.
  assert.strictEqual(out.picture.height, 20);
  assert.strictEqual(m.colourAt(out.picture, COLOURS, 4, 2), 'ink', 'pixels come with their sprite');
  for (const s of m.allSpritesOf(m.sheetTree(out.sheet))) {
    assert.deepStrictEqual(m.spriteProblems(out.picture, COLOURS, s.rect, false), [], s.path);
  }
});

test('a diff undoes and redoes a change, the picture\'s height with it', () => {
  const was = toyPicture();
  const out = m.resizeSprite(was, COLOURS, toySheet(), 'knight.1', { right: 8 });
  const diff = m.diffPictures(was, out.picture);
  assert.ok(diff.at.length > 0 && diff.at.length < was.width * out.picture.height);
  const back = m.applyDiff(out.picture, diff, true);
  assert.strictEqual(back.height, was.height);
  assert.ok(Buffer.from(back.rgba).equals(Buffer.from(was.rgba)), 'undo');
  const again = m.applyDiff(back, diff, false);
  assert.ok(Buffer.from(again.rgba).equals(Buffer.from(out.picture.rgba)), 'redo');
});

// --- a real sheet, opened, painted and saved ------------------------------------

// A copy of a game's sheet in a folder of its own, laid out as a game is, so
// that saving it writes nothing in the repository.
function copyOf(game, leaf) {
  const from = path.join(FILMATION, game, 'metadata', leaf);
  if (!fs.existsSync(from)) skip(game + '/metadata/' + leaf + ' is not here');
  const sheet = JSON.parse(fs.readFileSync(from, 'utf8'));
  const picture = path.resolve(path.dirname(from), sheet.sheet.file);
  if (!fs.existsSync(picture)) skip(path.basename(picture) + ' has not been converted here');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sheet-'));
  const json = path.join(root, 'game', 'metadata', leaf);
  const png = path.resolve(path.dirname(json), sheet.sheet.file);
  fs.mkdirSync(path.dirname(json), { recursive: true });
  fs.mkdirSync(path.dirname(png), { recursive: true });
  fs.copyFileSync(from, json);
  fs.copyFileSync(picture, png);
  return json;
}

test('a sheet opens, a stroke paints and undoes, and Save writes it', () => {
  const json = copyOf('knightlore', 'sprites.json');
  const file = SheetFile.load(json);
  const first = m.allSpritesOf(m.sheetTree(file.sheet))[0];
  const r = first.rect;
  const corner = m.colourAt(file.picture, file.colours, r.x, r.y);
  const want = corner === 'ink' ? 'paper' : 'ink';
  // The corner pixel, and one in the frame, which is refused.
  const done = file.paint([{ x: r.x, y: r.y, to: want }, { x: r.x - 1, y: r.y, to: want }]);
  assert.deepStrictEqual(done, [{ x: r.x, y: r.y, from: corner, to: want }]);
  assert.strictEqual(file.edited, true);
  file.apply(done, true);
  assert.strictEqual(m.colourAt(file.picture, file.colours, r.x, r.y), corner, 'undo');
  file.apply(done, false);
  file.save();
  assert.strictEqual(file.edited, false);
  assert.strictEqual(file.changedOnDisk(), false, 'our own Save is not a change from outside');
  const again = SheetFile.load(json);
  assert.strictEqual(m.colourAt(again.picture, again.colours, r.x, r.y), want, 'saved');
  // ...and nothing else moved: the frame is whole, as the build wants it.
  assert.deepStrictEqual(m.spriteProblems(again.picture, again.colours, r, false), []);
});

test('a resize is one change across both files, undone exactly, and saved as one line', () => {
  const json = copyOf('knightlore', 'sprites.json');
  const file = SheetFile.load(json);
  const text = file.text;
  const bytes = Buffer.from(file.picture.rgba);
  const first = m.allSpritesOf(m.sheetTree(file.sheet))[0];
  const out = m.resizeSprite(file.picture, file.colours, file.sheet, first.path, { top: 1 });
  const record = file.layout(out.picture, out.sheet);
  file.relayout(record, true);
  assert.ok(Buffer.from(file.picture.rgba).equals(bytes), 'undo put the picture back');
  assert.strictEqual(file.description(), text, 'undo put the description back');
  file.relayout(record, false);
  file.save();
  // The description changed in the sprite's own line and nowhere else, unless
  // it had to move -- then its columns may realign.
  const before = text.split('\r\n');
  const after = fs.readFileSync(json, 'utf8').split('\r\n');
  assert.strictEqual(after.length, before.length);
  const changed = after.filter((line, i) => line !== before[i]);
  assert.ok(changed.length >= 1 && (out.moved || changed.length === 1), changed.join('\n'));
  const again = SheetFile.load(json);
  for (const s of m.allSpritesOf(m.sheetTree(again.sheet))) {
    assert.deepStrictEqual(m.spriteProblems(again.picture, again.colours, s.rect, false), [], s.path);
  }
});

test('nothing painted, the PNG is the file itself, unencoded', () => {
  const json = copyOf('knightlore', 'sprites.json');
  const file = SheetFile.load(json);
  assert.ok(file.pngBytes().equals(fs.readFileSync(file.pngPath)));
});

test('lightkeep: a Melkhior sheet finds its picture two folders up, and its graphics', () => {
  const json = path.join(FILMATION, 'lightkeep', 'metadata', 'melkhior', 'doors.json');
  if (!fs.existsSync(json)) skip('lightkeep has no doors sheet');
  let file;
  try {
    file = SheetFile.load(json);
  } catch (err) {
    skip(err.message);
  }
  assert.strictEqual(path.relative(path.join(FILMATION, 'lightkeep'), file.pngPath),
                     path.join('art', 'melkhior', 'doors.png'));
  const drawn = graphicsFor(json);
  assert.strictEqual(drawn.prefix, 'doors:');
  assert.deepStrictEqual(m.graphicsDrawing(drawn.graphics, drawn.prefix).get('DoorTop1.0'), [202]);
  const own = graphicsFor(path.join(FILMATION, 'lightkeep', 'metadata', 'sprites.json'));
  assert.strictEqual(own.prefix, '');
});

test('a description that names a picture outside its game is refused', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sheet-'));
  const json = path.join(root, 'game', 'metadata', 'sprites.json');
  fs.mkdirSync(path.dirname(json), { recursive: true });
  fs.writeFileSync(json, JSON.stringify({ sheet: { file: '../../../elsewhere.png' }, group: {} }));
  assert.throws(() => SheetFile.load(json), /outside the game/);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
