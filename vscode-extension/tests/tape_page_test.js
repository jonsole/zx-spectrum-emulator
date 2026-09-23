// The tape's page, tape_view.html, as the extension assembles it.
//
//   node vscode-extension/tests/tape_page_test.js
//
// Run against fake_page.js's recording DOM: the page opens, draws its picture,
// lists its blocks, times and checks the tape for its scheme, and each thing it
// can do -- take a block off, type an address, switch scheme, ask for the
// designer -- comes back as the message tape_view.js acts on.

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
const PICTURE = fs.existsSync(SCR) ? fs.readFileSync(SCR).subarray(0, 6912)
  : Buffer.alloc(6912, 0x47);
const ORDER = [{ x: 11, y: 0, w: 10, h: 2 }, { x: 0, y: 8, w: 32, h: 8 }];
const CODE = Buffer.from([0x18, 0xFE, 0x00]);

// What tape_view.js's load() sends for a tape of one scheme or the other.
function load(scheme) {
  const tape = m.parseTape(m.serializeTape({
    meta: { version: 1 }, scheme, loaderAddress: null, loadingScreen: 'game.screen.json',
    blocks: [{ name: 'code', file: 'code.bin', address: 0x8000, offset: 0, length: null },
             { name: 'data', file: 'data.bin', address: 0x9000, offset: 0, length: null }],
    entry: 0x8000, output: null
  })).tape;
  return {
    type: 'load', name: 'game.tape.json', tape,
    blocks: [{ name: 'code', length: 3, problem: null, data: scheme === 'rom' ? CODE.toString('base64') : null },
             { name: 'data', length: 3, problem: null, data: scheme === 'rom' ? CODE.toString('base64') : null }],
    screen: PICTURE.toString('base64'), screenFile: 'game.screen.json', picture: 'LunarJetman.scr',
    order: ORDER, fastRomSeconds: 7.9, problems: []
  };
}

test('the page opens, draws the picture and lists the tape', () => {
  const p = page.open('tape_view.html');
  assert.deepStrictEqual(p.posted, [{ type: 'ready' }]);
  p.send(load('zx-tape-loader'));
  assert.strictEqual(p.el('name').textContent, 'game.tape.json');
  assert.ok(p.painted.some((d) => d.canvas === 'screen' && d.call === 'putImageData'), 'the picture was drawn');
  assert.ok(p.painted.some((d) => d.canvas === 'map' && d.call === 'fillRect'), 'the memory map was drawn');
  const rows = p.all('#blocks .row');
  assert.strictEqual(rows.length, 2);
  assert.ok(rows[0].textContent.includes('code'));
  assert.strictEqual(rows[0].children[0].value, '$8000');
  // Nothing stops it loading; the one thing worth knowing is that this short
  // order leaves most of the picture unsent -- the coverage check at work.
  assert.ok(!p.el('problems').textContent.includes('✖'), p.el('problems').textContent);
  assert.ok(p.el('problems').textContent.includes('never loads'), p.el('problems').textContent);
  assert.ok(p.el('screenLine').textContent.includes('2 rectangles'));
  assert.strictEqual(p.el('designScreen').disabled, false);
  // The time: 7.9s of BASIC and the fast part, as the model reckons it.
  const fast = m.fastSeconds(m.totalBits(m.patternRuns(new Uint8Array(PICTURE), ORDER)), [3, 3]);
  assert.ok(p.el('summary').textContent.includes((7.9 + fast).toFixed(1) + ' s'), p.el('summary').textContent);
});

test('taking a block off sends the tape back without it', () => {
  const p = page.open('tape_view.html');
  p.send(load('zx-tape-loader'));
  p.click(p.all('#blocks .row .drop')[0]);
  const sent = p.posted.pop();
  assert.strictEqual(sent.type, 'tape');
  assert.deepStrictEqual(sent.tape.blocks.map((b) => b.name), ['data']);
  assert.strictEqual(p.all('#blocks .row').length, 1);
});

test('typing an address sends it as it becomes one, and not before', () => {
  const p = page.open('tape_view.html');
  p.send(load('zx-tape-loader'));
  const entry = p.el('entry');
  p.type(entry, '$90');
  assert.strictEqual(p.posted.pop().tape.entry, 0x90);
  const before = p.posted.length;
  p.type(entry, '$9g');
  assert.strictEqual(p.posted.length, before, 'nothing sent for a half-typed address');
  assert.ok(entry.classList.contains('invalid'));
  // A block's own address box, the same way.
  const box = p.all('#blocks .row')[1].children[0];
  p.type(box, '$A000');
  assert.strictEqual(p.posted.pop().tape.blocks[1].address, 0xA000);
});

test('a block over the loader is an error, and building is refused', () => {
  const p = page.open('tape_view.html');
  const message = load('zx-tape-loader');
  message.tape.blocks[1].address = 0xFE50;
  p.send(message);
  assert.ok(p.el('problems').textContent.includes('would load over the loader itself'));
  assert.strictEqual(p.el('build').disabled, true);
  assert.strictEqual(p.el('buildRun').disabled, true);
});

test('the stack is a CLEAR address: moving it lets a block load where the stack was', () => {
  const p = page.open('tape_view.html');
  const message = load('zx-tape-loader');
  message.tape.blocks[1].address = 0x5F25;    // three bytes, into the default stack's $5F26-$5F29
  p.send(message);
  assert.strictEqual(p.el('stack').placeholder, '$5F41 (BASIC)');
  assert.ok(p.el('problems').textContent.includes('would load over the loader\'s stack ($5F26-$5F29)'));
  p.type(p.el('stack'), '$FE4D');
  assert.strictEqual(p.posted.pop().tape.stack, 0xFE4D);
  assert.ok(!p.el('problems').textContent.includes('✖'), p.el('problems').textContent);
  assert.strictEqual(p.el('build').disabled, false);
  // The ROM loader's own CLEAR is just below its lowest block.
  p.choose(p.el('scheme'), 'rom');
  p.type(p.el('stack'), '');
  assert.strictEqual(p.posted.pop().tape.stack, null);
  assert.strictEqual(p.el('stack').placeholder, '$5F24 (below)');
});

test('switching to the ROM loader sends the scheme, and there is no order to design', () => {
  const p = page.open('tape_view.html');
  p.send(load('zx-tape-loader'));
  p.choose(p.el('scheme'), 'rom');
  assert.strictEqual(p.posted.pop().tape.scheme, 'rom');
  assert.strictEqual(p.el('designScreen').disabled, true);
  assert.ok(p.el('loaderAddress').classList.contains('hidden'), 'no loader of its own to place');
});

test('a standard ROM tape is timed from the .tap it builds', () => {
  const p = page.open('tape_view.html');
  p.send(load('rom'));
  const message = load('rom');
  const tap = m.romTap(message.tape, new Uint8Array(PICTURE), [CODE, CODE], 'game');
  assert.ok(p.el('summary').textContent.includes(m.romTapeSeconds(tap).toFixed(1) + ' s'), p.el('summary').textContent);
  assert.ok(p.el('screenLine').textContent.includes('LOAD ""SCREEN$'));
});

test('the buttons ask the extension for what only it can do', () => {
  const p = page.open('tape_view.html');
  p.send(load('zx-tape-loader'));
  for (const id of ['designScreen', 'pick', 'addBlock', 'importTape', 'build', 'buildRun']) {
    p.click(p.el(id));
    assert.deepStrictEqual(p.posted.pop(), { type: id });
  }
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
