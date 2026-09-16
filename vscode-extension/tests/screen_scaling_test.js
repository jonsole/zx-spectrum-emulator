// Tests for screen_scaling.js -- how big the screen panel draws the picture.
// Plain Node, no vscode API:
//
//   node vscode-extension/tests/screen_scaling_test.js

const assert = require('assert');
const {
  layoutFor,
  prescaleFactor,
  scanlinesPossible,
  scanlineBand,
  normaliseView,
} = require('../screen_scaling');

let failures = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}

test('fitting in whole multiples picks the largest that fits', () => {
  // 800/352 = 2.27 and 700/312 = 2.24: two it is.
  assert.deepStrictEqual(layoutFor('fit-integer', 800, 700, 1), {
    canvasW: 704,
    canvasH: 624,
    cssW: 704,
    cssH: 624,
  });
});

test('whole multiples are of DEVICE pixels, so a scaled display gets its own', () => {
  // At 150% the same panel is 1200x1050 device pixels: three to a Spectrum
  // pixel fits, and is still the same size on screen as far as CSS knows.
  assert.deepStrictEqual(layoutFor('fit-integer', 800, 700, 1.5), {
    canvasW: 1056,
    canvasH: 936,
    cssW: 704,
    cssH: 624,
  });
});

test('fitting freely fills the tighter dimension exactly', () => {
  const l = layoutFor('fit', 800, 700, 1);
  assert.strictEqual(l.canvasH, 700);
  assert.strictEqual(l.canvasW, Math.round((352 * 700) / 312)); // 790, shape kept
});

test('a fixed scale is CSS pixels, whatever the panel', () => {
  // 2x is the old fixed size, and on a 125% display it is 2.5 device pixels a
  // Spectrum pixel -- which is exactly the case sharp bilinear is for.
  assert.deepStrictEqual(layoutFor('2', 300, 300, 1.25), {
    canvasW: 880,
    canvasH: 780,
    cssW: 704,
    cssH: 624,
  });
});

test('a panel smaller than the picture still draws it at one to one', () => {
  assert.deepStrictEqual(layoutFor('fit-integer', 200, 100, 1), {
    canvasW: 352,
    canvasH: 312,
    cssW: 352,
    cssH: 312,
  });
  assert.strictEqual(layoutFor('fit', 200, 100, 1).canvasW, 352);
});

test("sharp bilinear's first pass is the largest whole multiple under the canvas", () => {
  assert.strictEqual(prescaleFactor(790, 700), 2); // 2.24
  assert.strictEqual(prescaleFactor(1056, 936), 3); // exactly 3: nothing left to blend
  assert.strictEqual(prescaleFactor(352, 312), 1);
  assert.strictEqual(prescaleFactor(100, 100), 1); // never below 1
});

test('settings from outside fall back to the defaults', () => {
  assert.deepStrictEqual(normaliseView(undefined), {
    filter: 'nearest',
    scale: 'fit-integer',
    scanlines: 0,
  });
  assert.deepStrictEqual(normaliseView({ filter: 'lanczos', scale: '9', scanlines: 'dark' }), {
    filter: 'nearest',
    scale: 'fit-integer',
    scanlines: 0,
  });
  assert.deepStrictEqual(normaliseView({ filter: 'bilinear', scale: 'fit', scanlines: 40 }), {
    filter: 'bilinear',
    scale: 'fit',
    scanlines: 40,
  });
});

test('scanline darkness is a whole percentage from 0 to 100', () => {
  assert.strictEqual(normaliseView({ scanlines: -5 }).scanlines, 0);
  assert.strictEqual(normaliseView({ scanlines: 250 }).scanlines, 100);
  assert.strictEqual(normaliseView({ scanlines: 37.6 }).scanlines, 38);
  assert.strictEqual(normaliseView({ scanlines: '60' }).scanlines, 60);
});

test('scanlines need two device pixels to a line', () => {
  assert.strictEqual(scanlinesPossible(1), false); // 1x on an unscaled display
  assert.strictEqual(scanlinesPossible(1.5), false); // 1x at 150%
  assert.strictEqual(scanlinesPossible(2), true);
  assert.strictEqual(scanlinesPossible(2.56), true);
});

test('the gap is the lower half of a line, in whole pixels where the line is whole', () => {
  // 2 pixels: one lit, one gap -- the classic look.
  assert.deepStrictEqual(scanlineBand(2), { offset: 1, height: 1 });
  // 3 pixels: two lit, one gap, rather than one and a half of each.
  assert.deepStrictEqual(scanlineBand(3), { offset: 2, height: 1 });
  assert.deepStrictEqual(scanlineBand(4), { offset: 2, height: 2 });
  // A fractional line (Fit) gets a fractional gap, which the canvas shades at
  // its edges: the same on every line, since each line is the same height.
  const band = scanlineBand(2.5);
  assert.strictEqual(band.height, 1.25);
  assert.strictEqual(band.offset, 1.25);
});

test('the functions stand alone, so the webview can be given their source', () => {
  // getHtml() inlines the sizing functions as text. Rebuilding them
  // from that text, with nothing else in scope, must give the same answers.
  const rebuilt = new Function(
    `${layoutFor.toString()}\n${prescaleFactor.toString()}\n` +
      `${scanlinesPossible.toString()}\n${scanlineBand.toString()}\n` +
      'return { layoutFor, prescaleFactor, scanlinesPossible, scanlineBand };'
  )();
  assert.deepStrictEqual(rebuilt.layoutFor('fit', 800, 700, 1.5), layoutFor('fit', 800, 700, 1.5));
  assert.strictEqual(rebuilt.prescaleFactor(790, 700), 2);
  assert.strictEqual(rebuilt.scanlinesPossible(2), true);
  assert.deepStrictEqual(rebuilt.scanlineBand(3), scanlineBand(3));
});

if (failures > 0) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log('all passed');
