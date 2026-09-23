// The loading-screen designer, screen_designer.html, as the extension assembles it.
//
//   node vscode-extension/tests/screen_page_test.js
//
// Run against fake_page.js's recording DOM: the designer opens, draws the
// picture and its rectangles, lists the order, and each change it makes --
// filling from the picture, taking a rectangle out, clearing -- comes back as
// the whole order, which screen_view.js writes into the file.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const m = require('../tape_model');
const page = require('./fake_page');

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

const SCR = path.join(__dirname, '..', '..', 'examples', 'zx-tape-loader', 'LunarJetman.scr');
const PICTURE = fs.existsSync(SCR) ? fs.readFileSync(SCR).subarray(0, 6912) : (() => {
  const b = Buffer.alloc(6912, 0x47);
  b.fill(0xFF, 0, 256);
  return b;
})();
const ORDER = [{ x: 11, y: 0, w: 10, h: 2 }, { x: 2, y: 2, w: 28, h: 5 }, { x: 0, y: 8, w: 32, h: 8 }];

function opened() {
  const p = page.open('screen_designer.html');
  p.send({ type: 'load', picture: 'LunarJetman.scr', screen: PICTURE.toString('base64'), regions: ORDER, problems: [] });
  return p;
}

test('the designer opens, draws the picture and its rectangles, and lists the order', () => {
  const p = opened();
  assert.deepStrictEqual(p.posted[0], { type: 'ready' });
  assert.ok(p.painted.some((d) => d.canvas === 'screen' && d.call === 'putImageData'), 'the picture was drawn');
  // The overlay is redrawn whole each time (a resize, a change), so count what
  // the last drawing of it put there: one outline per rectangle.
  const overlay = p.painted.filter((d) => d.canvas === 'overlay');
  const last = overlay.map((d) => d.call).lastIndexOf('clearRect');
  assert.strictEqual(overlay.slice(last).filter((d) => d.call === 'strokeRect').length, ORDER.length,
                     'one outline per rectangle');
  assert.strictEqual(p.all('#list .row').length, ORDER.length);
  assert.ok(p.el('count').textContent.includes('3 rectangles'));
  assert.strictEqual(p.el('pictureName').textContent, 'LunarJetman.scr');
  const bits = m.totalBits(m.patternRuns(new Uint8Array(PICTURE), ORDER));
  assert.strictEqual(p.el('time').textContent, m.seconds(bits).toFixed(2) + ' s to load');
});

test('filling from the picture sends the automatic order', () => {
  const p = opened();
  p.click(p.el('auto'));
  const sent = p.posted.pop();
  assert.strictEqual(sent.type, 'order');
  assert.deepStrictEqual(sent.regions, m.autoRegions(new Uint8Array(PICTURE)));
});

test('taking a rectangle out sends the order without it', () => {
  const p = opened();
  p.click(p.all('#list .row .drop')[1]);
  const sent = p.posted.pop();
  assert.strictEqual(sent.type, 'order');
  assert.deepStrictEqual(sent.regions, [ORDER[0], ORDER[2]]);
  assert.strictEqual(p.all('#list .row').length, 2);
});

test('clearing sends an empty order, and the empty page says what to do', () => {
  const p = opened();
  p.click(p.el('clear'));
  assert.deepStrictEqual(p.posted.pop(), { type: 'order', regions: [] });
  assert.ok(!p.el('empty').classList.contains('hidden'));
});

test('an undo from elsewhere reloads the order the page shows', () => {
  const p = opened();
  p.send({ type: 'load', picture: 'LunarJetman.scr', screen: PICTURE.toString('base64'),
           regions: [ORDER[0]], problems: [] });
  assert.strictEqual(p.all('#list .row').length, 1);
});

test('Picture and Copy as Python ask the extension', () => {
  const p = opened();
  p.click(p.el('pick'));
  assert.deepStrictEqual(p.posted.pop(), { type: 'pick' });
  p.click(p.el('python'));
  assert.deepStrictEqual(p.posted.pop(), { type: 'python', text: m.pythonFor(ORDER) });
});

test('with no picture it says so rather than drawing an empty screen', () => {
  const p = page.open('screen_designer.html');
  p.send({ type: 'load', picture: '', screen: null, regions: [], problems: [] });
  assert.ok(!p.el('noScreen').classList.contains('hidden'));
  assert.strictEqual(p.el('auto').disabled, true);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
