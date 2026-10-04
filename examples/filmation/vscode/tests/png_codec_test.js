// Tests for png_codec.js: reading the sheets' PNGs, and writing them back.
//
//   node examples/filmation/vscode/tests/png_codec_test.js
//
// What the right pixels are is not taken from the decoder. The CRC is
// checked against the standard's own check value, a picture made here by
// hand must come back exactly, and every real sheet must decode to the
// magenta frame its description says surrounds each sprite -- something only
// a correct decoder could find, at hundreds of places a sheet.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const png = require('../png_codec');
const model = require('../sprite_sheet_model');
const layout = require('../game_layout');

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

test('the CRC is the standard one: "123456789" is CBF43926', () => {
  assert.strictEqual(png.crc32(Buffer.from('123456789', 'latin1')), 0xcbf43926);
});

test('a picture made by hand comes back exactly, transparent pixels and all', () => {
  // Three by two: the four colours a sheet uses, a clear pixel with colour
  // in it, and one half see-through -- the two a canvas would not keep.
  const rgba = new Uint8Array([
    255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0,
    255, 0, 0, 255, 12, 34, 56, 0, 255, 0, 255, 128
  ]);
  const back = png.decode(png.encode({ width: 3, height: 2, rgba: rgba }));
  assert.strictEqual(back.width, 3);
  assert.strictEqual(back.height, 2);
  assert.deepStrictEqual(Array.from(back.rgba), Array.from(rgba));
});

test('every filter decodes: a picture written one filter a row reads back', () => {
  // Five rows, filters 0 to 4, built here byte by byte so the decoder's
  // unfiltering is checked against a hand-made encoding, not its partner.
  const width = 2;
  const want = [];
  for (let y = 0; y < 5; y++) {
    for (let x = 0; x < width; x++) want.push(10 * y + x, 3 * y, 200 - y, 255 - x);
  }
  const stride = width * 4;
  const raw = [];
  for (let y = 0; y < 5; y++) {
    raw.push(y);
    for (let i = 0; i < stride; i++) {
      const v = want[y * stride + i];
      const left = i >= 4 ? want[y * stride + i - 4] : 0;
      const above = y ? want[(y - 1) * stride + i] : 0;
      const corner = y && i >= 4 ? want[(y - 1) * stride + i - 4] : 0;
      const p = left + above - corner;
      const pa = Math.abs(p - left);
      const pb = Math.abs(p - above);
      const pc = Math.abs(p - corner);
      const paeth = pa <= pb && pa <= pc ? left : pb <= pc ? above : corner;
      const guess = [0, left, above, (left + above) >> 1, paeth][y];
      raw.push((v - guess) & 0xff);
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(5, 4);
  header[8] = 8;
  header[9] = 6;
  const chunk = (type, body) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(body.length, 0);
    head.write(type, 4, 'latin1');
    const tail = Buffer.alloc(4);
    tail.writeUInt32BE(png.crc32(Buffer.concat([head.subarray(4), body])), 0);
    return Buffer.concat([head, body, tail]);
  };
  const file = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(Buffer.from(raw))),
    chunk('IEND', Buffer.alloc(0))
  ]);
  assert.deepStrictEqual(Array.from(png.decode(file).rgba), want);
});

test('what it cannot read, it says, rather than reading it wrongly', () => {
  assert.throws(() => png.decode(Buffer.from('not a png at all')), /not a PNG/);
});

// Every sheet in the repository: each description and the picture it names.
function sheets() {
  const out = [];
  for (const game of fs.readdirSync(FILMATION)) {
    const meta = path.join(FILMATION, game, 'metadata');
    const candidates = [path.join(meta, 'sprites.json')];
    const melkhior = path.join(meta, 'melkhior');
    if (fs.existsSync(melkhior)) {
      for (const f of fs.readdirSync(melkhior)) if (f.endsWith('.json')) candidates.push(path.join(melkhior, f));
    }
    for (const file of candidates) {
      if (!fs.existsSync(file)) continue;
      const sheet = JSON.parse(fs.readFileSync(file, 'utf8'));
      const picture = layout.withinGame(path.dirname(file), (sheet.sheet || {}).file || 'sprites.png');
      if (picture && fs.existsSync(picture)) out.push({ file, sheet, picture });
    }
  }
  return out;
}

test('every real sheet decodes to a frame round every sprite, and round-trips', () => {
  const found = sheets();
  if (!found.length) skip('no sheet pictures here');
  let frames = 0;
  for (const s of found) {
    const picture = png.decode(fs.readFileSync(s.picture));
    const colours = model.coloursOf(s.sheet);
    for (const sprite of model.allSpritesOf(model.sheetTree(s.sheet))) {
      for (const p of model.frameOf(sprite.rect)) {
        assert.strictEqual(model.colourAt(picture, colours, p.x, p.y), 'border',
          path.relative(FILMATION, s.file) + ' ' + sprite.path + ' at ' + p.x + ',' + p.y);
      }
      frames++;
    }
    const back = png.decode(png.encode(picture));
    assert.ok(Buffer.from(back.rgba).equals(Buffer.from(picture.rgba)),
              path.relative(FILMATION, s.file) + ' did not come back the same');
  }
  assert.ok(frames > 300, 'only ' + frames + ' sprites checked');
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
