// Tests for tape_model.js -- the tape designer's screen rectangles, what they
// cost on tape and what has arrived part way through, and the rest of a
// design: its blocks, addresses, timings and whether it can load. Plain Node,
// no vscode API and no test framework:
//
//   node vscode-extension/tests/tape_model_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/tape_model_test.js)
//
// The last tests run against the real thing: examples/zx-tape-loader's own
// loading screen and hand-written order, with the run list and bit count taken
// from what its loader.py really emits, and -- when the repo's Python can import
// them -- loader.py, scripts/tape_rom.py and scripts/tape_screen.py, given the
// same tapes as the model and required to say and build the same thing. That
// submodule is optional, so they skip when it is not checked out.

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const m = require('../tape_model');

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

// A screen with one byte of ink set in the cell at (col, row), so a test can
// say where content is without spelling out a display file.
function screenWithInk(cells) {
  const screen = new Uint8Array(m.SCREEN_BYTES);
  for (const [col, row] of cells) {
    screen[m.pixelAddress(col, row * 8 + 3)] = 0xFF;
  }
  return screen;
}

test('the display file layout is the ULA\'s own', () => {
  assert.strictEqual(m.pixelAddress(0, 0), 0);
  assert.strictEqual(m.pixelAddress(31, 0), 31);
  assert.strictEqual(m.pixelAddress(0, 1), 256);       // next pixel line, same cell row
  assert.strictEqual(m.pixelAddress(0, 8), 32);        // next cell row
  assert.strictEqual(m.pixelAddress(0, 64), 2048);     // second third
  assert.strictEqual(m.pixelAddress(0, 191), 6112 + 32 - 32);
  assert.strictEqual(m.attrAddress(0, 0), 0);
  assert.strictEqual(m.attrAddress(5, 9), 37);
  assert.strictEqual(m.attrAddress(31, 191), 767);
});

test('a region is brought inside the screen', () => {
  assert.deepStrictEqual(m.clampRegion({ x: -4, y: -1, w: 2, h: 2 }), { x: 0, y: 0, w: 2, h: 2 });
  assert.deepStrictEqual(m.clampRegion({ x: 30, y: 22, w: 9, h: 9 }), { x: 30, y: 22, w: 2, h: 2 });
  assert.deepStrictEqual(m.clampRegion({ x: 0, y: 0, w: 0, h: 0 }), { x: 0, y: 0, w: 1, h: 1 });
  assert.deepStrictEqual(m.clampRegion({ x: 1.6, y: 2.4, w: 3.5, h: 1 }), { x: 2, y: 2, w: 4, h: 1 });
  // The whole screen is legal: 32 is exactly what the 5-bit length field holds.
  assert.deepStrictEqual(m.clampRegion({ x: 0, y: 0, w: 32, h: 24 }), { x: 0, y: 0, w: 32, h: 24 });
});

test('the automatic pass skips blank rows and bounds each run of content', () => {
  const screen = screenWithInk([[4, 2], [9, 2], [6, 3], [20, 10]]);
  assert.deepStrictEqual(m.autoRegions(screen), [
    { x: 4, y: 2, w: 6, h: 2 },     // rows 2 and 3 together, columns 4..9
    { x: 20, y: 10, w: 1, h: 1 }
  ]);
  assert.deepStrictEqual(m.autoRegions(new Uint8Array(m.SCREEN_BYTES)), []);
});

test('content in the bottom row still ends its run', () => {
  // The run is closed by the sentinel row past the end of the screen, not by a
  // blank row after it -- so content at row 23 must not be dropped.
  const screen = screenWithInk([[0, 23]]);
  assert.deepStrictEqual(m.autoRegions(screen), [{ x: 0, y: 23, w: 1, h: 1 }]);
});

test('a run is the attributes, then each pixel line without its blank ends', () => {
  const screen = new Uint8Array(m.SCREEN_BYTES);
  screen[m.pixelAddress(5, 3)] = 0x01;          // one byte, in the middle of a 4-wide region
  const runs = m.regionRuns(screen, { x: 4, y: 0, w: 4, h: 1 });
  assert.strictEqual(runs.length, 2);
  assert.deepStrictEqual(runs[0], { offset: m.BITMAP_BYTES + 4, length: 4, attr: true });
  assert.deepStrictEqual(runs[1], { offset: m.pixelAddress(5, 3), length: 1, attr: false });
});

test('the attributes are sent whole, even where there is no ink at all', () => {
  // An empty rectangle still costs its attributes: that is how a pattern
  // paints a block of colour before anything is drawn in it.
  const runs = m.regionRuns(new Uint8Array(m.SCREEN_BYTES), { x: 0, y: 0, w: 32, h: 2 });
  assert.strictEqual(runs.length, 2);
  assert.ok(runs.every((run) => run.attr && run.length === 32));
  assert.strictEqual(m.totalBits(m.patternRuns(new Uint8Array(m.SCREEN_BYTES),
    [{ x: 0, y: 0, w: 32, h: 2 }])), 2 * (18 + 32 * 8) + 5);
});

test('every bit costs the same, so a pattern\'s time is its bit count', () => {
  assert.strictEqual(m.BIT_TSTATES, (69888 / 8) / 13);
  assert.ok(Math.abs(m.seconds(51095) - 9.81) < 0.01);
  assert.strictEqual(m.seconds(0), 0);
});

test('the reveal arrives byte by byte, in the order the rectangles are in', () => {
  const screen = new Uint8Array(m.SCREEN_BYTES).fill(0xFF);
  const regions = [{ x: 0, y: 0, w: 2, h: 1 }, { x: 4, y: 0, w: 2, h: 1 }];
  const runs = m.patternRuns(screen, regions);

  assert.strictEqual(m.loadedAt(runs, 0).indexOf(1), -1);          // nothing yet
  // Part way through the first run's header: still nothing on the screen.
  assert.strictEqual(m.loadedAt(runs, m.HEADER_BITS - 1).indexOf(1), -1);
  // One byte past it: exactly one byte of the first rectangle's attributes.
  const early = m.loadedAt(runs, m.HEADER_BITS + 8);
  assert.strictEqual(early[m.BITMAP_BYTES], 1);
  assert.strictEqual(early[m.BITMAP_BYTES + 1], 0);
  // The second rectangle has not started while the first is still going.
  assert.strictEqual(early[m.BITMAP_BYTES + 4], 0);

  const all = m.loadedAt(runs, m.totalBits(runs));
  for (const region of regions) {
    for (const run of m.regionRuns(screen, region)) {
      for (let i = 0; i < run.length; i++) {
        assert.strictEqual(all[run.offset + i], 1);
      }
    }
  }
});

test('coverage says what is missed, what is empty and what is sent twice', () => {
  const screen = screenWithInk([[0, 0], [10, 10]]);
  const one = m.coverage(screen, [{ x: 0, y: 0, w: 1, h: 1 }]);
  assert.strictEqual(one.missed, 1);          // the cell at 10,10 is never sent
  assert.strictEqual(one.blank, 0);
  assert.strictEqual(one.repeated, 0);

  const twice = m.coverage(screen, [{ x: 0, y: 0, w: 1, h: 1 }, { x: 0, y: 0, w: 1, h: 1 }]);
  assert.strictEqual(twice.missed, 1);
  // The second pass resends the attribute byte and the one line of ink.
  assert.strictEqual(twice.repeated, 2);

  const wide = m.coverage(screen, [{ x: 0, y: 0, w: 32, h: 24 }]);
  assert.strictEqual(wide.missed, 0);
  assert.strictEqual(wide.blank, 32 * 24 - 2);
});

test('addresses read the ways a Spectrum programmer writes them', () => {
  assert.strictEqual(m.parseAddress('$7000'), 0x7000);
  assert.strictEqual(m.parseAddress('#7000'), 0x7000);
  assert.strictEqual(m.parseAddress('0x7000'), 0x7000);
  assert.strictEqual(m.parseAddress('28672'), 0x7000);
  assert.strictEqual(m.parseAddress(28672), 0x7000);
  assert.strictEqual(m.parseAddress(' $ffff '), 0xFFFF);
  assert.strictEqual(m.parseAddress(''), null);
  assert.strictEqual(m.parseAddress(null), null);
  assert.ok(Number.isNaN(m.parseAddress('$10000')));
  assert.ok(Number.isNaN(m.parseAddress('seven')));
  assert.ok(Number.isNaN(m.parseAddress(-1)));
  assert.strictEqual(m.formatAddress(0x7000), '$7000');
  assert.strictEqual(m.formatAddress(0xfe4e), '$FE4E');
});

test('a tape survives a round trip, blocks keyed by name and in tape order', () => {
  const tape = {
    meta: { version: 1, comment: 'hi' },
    scheme: 'zx-tape-loader',
    loaderAddress: 0x9000,
    loadingScreen: 'game.screen.json',
    blocks: [{ name: 'code', file: 'code.bin', address: 0x7000, offset: 0, length: null },
             { name: 'level one', file: 'game.tap', address: 0x8000, offset: 23, length: 100 }],
    entry: 0x7000,
    stack: 0xF000,
    output: 'game.wav'
  };
  const text = m.serializeTape(tape);
  const back = m.parseTape(text);
  assert.deepStrictEqual(back.problems, []);
  assert.deepStrictEqual(back.tape, tape);
  const raw = JSON.parse(text);
  assert.deepStrictEqual(Object.keys(raw.blocks), ['code', 'level one']);   // the key is the name
  assert.strictEqual(raw.blocks.code.name, undefined);
  assert.strictEqual(raw.loaderAddress, '$9000');
  assert.strictEqual(raw.stack, '$F000');
  assert.ok(m.parseTape('{"stack": "high"}').problems[0].includes('stack address'));
  assert.strictEqual(text.split('\n').filter((line) => line.includes('"file"')).length, 2);

  // A standard ROM tape has no loader of its own to place.
  const rom = m.serializeTape(Object.assign({}, tape, { scheme: 'rom' }));
  assert.strictEqual(JSON.parse(rom).loaderAddress, undefined);

  const empty = m.serializeTape(m.emptyTape());
  assert.deepStrictEqual(m.parseTape(empty).tape, m.emptyTape());

  assert.ok(m.parseTape('not json').problems[0].includes('not JSON'));
  assert.ok(m.parseTape('[]').problems[0].includes('JSON object'));
  assert.ok(m.parseTape('{"scheme": "speedlock"}').problems[0].includes('not a loading scheme'));
  assert.ok(m.parseTape('{"entry": "soon"}').problems[0].includes('entry address'));
  assert.ok(m.parseTape('{"blocks": {"x": {"address": 1}}}').problems[0].includes('needs a "file"'));
  assert.ok(m.parseTape('{"blocks": [1]}').problems[0].includes('keyed by name'));
});

test('a loading screen survives a round trip, and says what is wrong with it', () => {
  const screen = { meta: { version: 1 }, picture: 'art/title.scr', order: [{ x: 1, y: 2, w: 3, h: 4 }] };
  const text = m.serializeScreen(screen);
  assert.deepStrictEqual(m.parseScreen(text), { screen, problems: [] });
  assert.strictEqual(text.split('\n').filter((line) => line.includes('"x"')).length, 1);
  assert.deepStrictEqual(m.parseScreen(m.serializeScreen(m.emptyScreen())).screen, m.emptyScreen());
  const off = m.parseScreen('{"picture": "a.scr", "order": [{"x": 30, "y": 0, "w": 8, "h": 1}]}');
  assert.ok(off.problems[0].includes('does not fit'));
  assert.deepStrictEqual(off.screen.order, [{ x: 30, y: 0, w: 2, h: 1 }]);
  assert.ok(m.parseScreen('{"order": []}').problems[0].includes('"picture"'));
});

test('a fast block costs its header and eight bits a byte, and the tape its leader and tail', () => {
  assert.strictEqual(m.blockBits(3), 32 + 24);
  const leader = (1024 * 2168 + 2 * 600) / 3500000;
  const bits = (5 + 32 + 32 + 8 + 32) * m.BIT_TSTATES / 3500000;
  assert.ok(Math.abs(m.fastSeconds(m.END_BITS, [1]) - (leader + bits)) < 1e-9);
});

test('the ROM scheme\'s BASIC loader is the program a person would type', () => {
  // 10 CLEAR 32767: POKE 23739,111: LOAD ""SCREEN$: LOAD ""CODE: RANDOMIZE USR 32768,
  // spelt out token by token from the 48K ROM's table: CLEAR $FD, POKE $F4,
  // LOAD $EF, SCREEN$ $AA, CODE $AF, RANDOMIZE $F9, USR $C0, and each number as
  // its digits then $0E and the five-byte small-integer form.
  const number = (digits, value) => Array.from(digits).map((c) => c.charCodeAt(0))
    .concat([0x0E, 0, 0, value & 0xFF, value >> 8, 0]);
  const body = [0xFD].concat(number('32767', 32767), [0x3A],
    [0xF4], number('23739', 0x5CBB), [0x2C], number('111', 111), [0x3A],
    [0xEF, 0x22, 0x22, 0xAA, 0x3A],
    [0xEF, 0x22, 0x22, 0xAF, 0x3A],
    [0xF9, 0xC0], number('32768', 32768), [0x0D]);
  const tape = { scheme: 'rom', blocks: [{ name: 'code', address: 0x8000 }], entry: 0x8000 };
  assert.deepStrictEqual(m.romLoaderProgram(tape, [3], true), [0x00, 10, body.length, 0].concat(body));
  // No screen, no LOAD ""SCREEN$.
  assert.ok(!m.romLoaderProgram(tape, [3], false).includes(0xAA));
  // A stack of its own is the CLEAR's number instead: CLEAR 61440.
  const high = m.romLoaderProgram(Object.assign({ stack: 0xF000 }, tape), [3], true);
  assert.deepStrictEqual(high.slice(4, 4 + 12), [0xFD].concat(number('61440', 0xF000)));
});

test('the ROM scheme\'s .tap is headed, flagged and checksummed', () => {
  const tape = { scheme: 'rom', blocks: [{ name: 'code', address: 0x8000 }], entry: 0x8000 };
  const tap = m.romTap(tape, null, [Uint8Array.from([1, 2, 3])], 'mygame');
  const blocks = [];
  for (let at = 0; at < tap.length;) {
    const length = tap[at] | (tap[at + 1] << 8);
    blocks.push(tap.subarray(at + 2, at + 2 + length));
    at += 2 + length;
  }
  assert.strictEqual(blocks.length, 4);                     // program header and body, code header and body
  for (const block of blocks) {
    assert.strictEqual(block.reduce((a, b) => a ^ b, 0), 0);   // flag ^ data ^ checksum
  }
  assert.deepStrictEqual(Array.from(blocks[0].subarray(0, 12)),
    [0x00, 0, 0x6D, 0x79, 0x67, 0x61, 0x6D, 0x65, 0x20, 0x20, 0x20, 0x20]);   // Program: "mygame    "
  assert.strictEqual(blocks[0][14], 10);                   // autostarts at line 10
  assert.deepStrictEqual(Array.from(blocks[2].subarray(0, 2)), [0x00, 3]);    // a CODE header
  assert.strictEqual(blocks[2][14] | (blocks[2][15] << 8), 0x8000);          // loading at $8000
  assert.deepStrictEqual(Array.from(blocks[3]), [0xFF, 1, 2, 3, 0xFF ^ 1 ^ 2 ^ 3]);
});

test('a standard tape gives up its CODE files by name, its screen and its USR address', () => {
  // A BASIC loader ending RANDOMIZE USR 32768, then a SCREEN$ and two CODE files
  // of the same name.
  const basic = Uint8Array.from([0xF9, 0xC0, 0x33, 0x32, 0x37, 0x36, 0x38, 0x0E, 0x00, 0x00, 0x00, 0x80, 0x00, 0x0D]);
  const header = (type, name, length, param) => {
    const h = new Uint8Array(17);
    h[0] = type;
    h.set(Array.from(name.padEnd(10)).map((c) => c.charCodeAt(0)), 1);
    h[11] = length & 255; h[12] = length >> 8; h[13] = param & 255; h[14] = param >> 8;
    return h;
  };
  const blocks = [
    { flag: 0, data: header(0, 'loader', basic.length, 10), offset: 3 },
    { flag: 255, data: basic, offset: 24 },
    { flag: 0, data: header(3, 'screen', 6912, 16384), offset: 42 },
    { flag: 255, data: new Uint8Array(6912), offset: 63 },
    { flag: 0, data: header(3, 'game', 1000, 32768), offset: 6979 },
    { flag: 255, data: new Uint8Array(1000), offset: 7000 },
    { flag: 0, data: header(3, 'game', 10, 40000), offset: 8003 },
    { flag: 255, data: new Uint8Array(10), offset: 8024 }
  ];
  assert.strictEqual(m.findUsrAddress(basic), 32768);
  assert.deepStrictEqual(m.tapeContents(blocks, ['game']), {
    code: [{ name: 'game 2', address: 32768, length: 1000, offset: 7000 },
           { name: 'game 3', address: 40000, length: 10, offset: 8024 }],
    entry: 32768,
    screen: true
  });
  assert.strictEqual(m.uniqueName('  ', []), 'block');
  assert.strictEqual(m.findUsrAddress(Uint8Array.from([0xC0, 0x31])), null);
});

test('the fast loader\'s checks catch everything that would stop its tape loading', () => {
  const tape = (fields) => Object.assign({ scheme: 'zx-tape-loader', loaderAddress: null, entry: 0x8000,
    blocks: [{ name: 'a', address: 0x8000 }] }, fields);
  const check = (fields, lengths, screen) => m.checkTape(tape(fields), lengths || [100], !!screen);

  assert.deepStrictEqual(check({}), { errors: [], warnings: [] });
  assert.ok(check({ loaderAddress: 0x7000 }).errors[0].includes('must fit in $8000-$FFFF'));
  assert.ok(check({ blocks: [{ name: 'a', address: 0xFE00 }] }, [1000]).errors
    .some((e) => e.includes('block "a" ($FE00-$101E7) would load over the loader itself ($FE4E-$FFFE)')));
  assert.ok(check({ blocks: [{ name: 'a', address: 0x5F00 }] }).errors[0].includes('loader\'s stack'));
  assert.ok(check({ blocks: [{ name: 'a', address: 0x5F2C }], entry: 0x5F2C }).warnings[0].includes('BASIC\'s stack'));
  assert.ok(check({ blocks: [{ name: 'a', address: 0x5000 }], entry: 0x5000 }, [100], true).warnings[0]
    .includes('over the loading screen'));
  assert.ok(check({ entry: null }).errors[0].includes('no entry address'));
  assert.ok(check({ entry: 0 }).warnings[0].includes('not in any block'));
  assert.ok(check({}, [null]).errors[0].includes('can\'t be read'));
  assert.ok(check({ blocks: [{ name: 'a', address: 0x8000 }, { name: 'b', address: 0x8010 }] }, [100, 10])
    .warnings[0].includes('block "b" ($8010-$8019) loads over part of block "a"'));
  // Moving the loader frees the top of RAM.
  assert.deepStrictEqual(check({ loaderAddress: 0x9000, blocks: [{ name: 'a', address: 0xFE00 }], entry: 0xFE00 },
    [512]), { errors: [], warnings: [] });

  // The default stack: CLEAR $5F41, SP $17 below it at $5F2A, two calls below
  // that down to $5F26.
  assert.deepStrictEqual(m.stackSpans(0x5F41), { live: [0x5F26, 0x5F2A], basic: [0x5F2A, 0x5F42] });
  assert.ok(check({ blocks: [{ name: 'a', address: 0x5F00 }] }).errors[0]
    .includes('would load over the loader\'s stack ($5F26-$5F29)'));
  // Pentagram's shape, 31K at $5E00, loads with the stack moved to just under
  // the loader: CLEAR $FE4D, SP $FE36, live $FE32-$FE35 -- warned only that a
  // failed load can't go back to the BASIC it has loaded over.
  assert.deepStrictEqual(check({ stack: 0xFE4D, blocks: [{ name: 'a', address: 0x5E00 }], entry: 0x5E00 }, [31000]),
    { errors: [], warnings: ['block "a" ($5E00-$D717) loads over the BASIC loader, so a failed load can\'t return to BASIC'] });
  assert.ok(check({ stack: 0xFE4D, blocks: [{ name: 'a', address: 0xFE00 }], entry: 0xFE00 }, [0x34]).errors[0]
    .includes('would load over the loader\'s stack ($FE32-$FE35)'));
  assert.ok(check({ stack: 0x5F00 }).errors[0].includes('must be at $5F41 or above'));
  // The loader at the top of RAM starts at $FE4E; a CLEAR above it runs into it.
  assert.ok(check({ stack: 0xFE4E }).errors[0].includes('the stack at $FE4E ($FE33-$FE4E) runs into the loader'));
});

test('the ROM scheme\'s checks keep blocks above its BASIC loader and stack', () => {
  const tape = { scheme: 'rom', entry: 0x6000, blocks: [{ name: 'a', address: 0x6000 }] };
  assert.deepStrictEqual(m.checkTape(tape, [100], false), { errors: [], warnings: [] });
  // Nothing about a loader of its own, or its stack at $5F26: that is the fast loader's.
  const low = Object.assign({}, tape, { blocks: [{ name: 'a', address: 0x5D00 }], entry: 0x5D00 });
  const lowest = m.PROG + m.romLoaderProgram(low, [100], false).length + m.ROM_HEADROOM;
  assert.strictEqual(m.romLowest(low, [100], false), lowest);
  assert.deepStrictEqual(m.checkTape(low, [100], false).errors,
    ['block "a" ($5D00-$5D63) starts below ' + m.formatAddress(lowest) + ', which the BASIC loader and its stack need']);
  const high = Object.assign({}, tape, { blocks: [{ name: 'a', address: 0xFF00 }], entry: 0xFF00 });
  assert.deepStrictEqual(m.checkTape(high, [256], false), { errors: [], warnings: [] });
  // A stack of its own: $40 under the CLEAR is kept clear, and the CLEAR must
  // be above the BASIC loader's workspace.
  assert.deepStrictEqual(m.checkTape(Object.assign({ stack: 0x6080 }, tape), [100], false).errors,
    ['block "a" ($6000-$6063) would load over the stack ($6040-$6080)']);
  assert.deepStrictEqual(m.checkTape(Object.assign({ stack: 0x60A3 }, tape), [100], false).errors,
    ['block "a" ($6000-$6063) would load over the stack ($6063-$60A3)']);
  assert.deepStrictEqual(m.checkTape(Object.assign({ stack: 0x60A4 }, tape), [100], false),
    { errors: [], warnings: [] });
  assert.deepStrictEqual(m.checkTape(Object.assign({ stack: 0x5FFF }, tape), [100], false),
    { errors: [], warnings: [] });
  const lowestHere = m.romLowest(Object.assign({ stack: 0x5D00 }, tape), [100], false);
  assert.deepStrictEqual(m.checkTape(Object.assign({ stack: 0x5D00 }, tape), [100], false).errors,
    ['the stack at $5D00 must be at ' + m.formatAddress(lowestHere - 1) +
     ' or above: any lower and CLEAR would put it in the BASIC loader\'s own workspace']);
});

test('the memory map has each scheme\'s fixed parts and each block', () => {
  const fast = m.memoryMap({ scheme: 'zx-tape-loader', loaderAddress: 0x9000, entry: null,
    blocks: [{ name: 'a', address: 0x8000 }, { name: 'b', address: null }] }, [256, 10], false);
  assert.deepStrictEqual(fast.map((s) => s.kind), ['rom', 'screen', 'stack', 'loader', 'block']);
  assert.deepStrictEqual(fast[3], { start: 0x9000, end: 0x9000 + 433, kind: 'loader', label: 'loader' });
  assert.strictEqual(fast[4].label, 'a');
  const rom = m.memoryMap({ scheme: 'rom', entry: null, blocks: [{ name: 'a', address: 0x8000 }] }, [256], false);
  assert.deepStrictEqual(rom.map((s) => s.kind), ['rom', 'screen', 'stack', 'block']);
  assert.strictEqual(rom[2].end, m.romLowest({ scheme: 'rom', entry: null, blocks: [{ name: 'a', address: 0x8000 }] },
    [256], false));
});

test('the Python form is gen_block calls in order', () => {
  assert.strictEqual(m.pythonFor([{ x: 11, y: 0, w: 10, h: 2 }, { x: 2, y: 2, w: 28, h: 5 }]),
    'gen_block(gen, data, 11, 0, 10, 2)\ngen_block(gen, data, 2, 2, 28, 5)');
  assert.strictEqual(m.pythonFor([]), '');
});

// --- against the real loader, the builder and the repo's own files --------------

const ROOT = path.join(__dirname, '..', '..');
const LOADER = path.join(ROOT, 'examples', 'zx-tape-loader');
const SCR = path.join(LOADER, 'LunarJetman.scr');

// build_lunarjetman_tape.py's hand-written order, and what loader.py emits for
// it: 341 runs and 51095 bits, recorded by driving the real gen_block.
const JETMAN = [
  { x: 11, y: 0, w: 10, h: 2 }, { x: 2, y: 2, w: 28, h: 5 }, { x: 1, y: 0, w: 30, h: 2 },
  { x: 1, y: 2, w: 1, h: 5 }, { x: 30, y: 2, w: 1, h: 5 }, { x: 1, y: 7, w: 30, h: 1 },
  { x: 14, y: 16, w: 18, h: 6 }, { x: 0, y: 8, w: 32, h: 8 }, { x: 0, y: 16, w: 14, h: 6 }
];

function jetmanScreen() {
  try {
    const bytes = fs.readFileSync(SCR);
    return bytes.length >= m.SCREEN_BYTES ? new Uint8Array(bytes.subarray(0, m.SCREEN_BYTES)) : null;
  } catch (err) {
    return null;
  }
}

const screen = jetmanScreen();
if (!screen) {
  console.log('skip examples/zx-tape-loader is not checked out');
} else {
  test('the real screen costs what gen_block spends on it', () => {
    const runs = m.patternRuns(screen, JETMAN);
    assert.strictEqual(runs.length, 341);
    assert.strictEqual(m.totalBits(runs), 51095);
    assert.ok(Math.abs(m.seconds(m.totalBits(runs)) - 9.81) < 0.01);
    assert.strictEqual(runs[0].attr, true);
    assert.strictEqual(runs[0].offset, m.BITMAP_BYTES + 11);
  });

  test('the hand-written order misses the far right column, as the real tape does', () => {
    const hand = m.coverage(screen, JETMAN);
    // Rows 0-7 of that order stop at column 30, so three cells of artwork in
    // column 31 -- two stray pixels and a whole 8x8 glyph at row 7 -- never
    // reach the screen when the real tape loads.
    assert.strictEqual(hand.missed, 3);
    for (const row of [2, 4, 7]) {
      assert.ok(m.cellHasInk(screen, 31, row));
      assert.strictEqual(hand.covered[row * m.COLUMNS + 31], 0);
    }
    // The title box is deliberately sent before the wider pass over the same rows.
    assert.strictEqual(hand.repeated, 136);
    const auto = m.coverage(screen, m.autoRegions(screen));
    assert.strictEqual(auto.missed, 0);
    assert.strictEqual(auto.repeated, 0);
  });

  test('the automatic pass on the real screen is one full-width block', () => {
    assert.deepStrictEqual(m.autoRegions(screen), [{ x: 0, y: 0, w: 32, h: 22 }]);
  });

  test('the BASIC loader\'s own USR is where its machine code starts', () => {
    const tap = fs.readFileSync(path.join(LOADER, 'loader.tap'));
    const blocks = [];
    for (let at = 0; at + 2 <= tap.length;) {
      const length = tap[at] | (tap[at + 1] << 8);
      blocks.push({ flag: tap[at + 2], data: tap.subarray(at + 3, at + 2 + length - 1), offset: at + 3 });
      at += 2 + length;
    }
    assert.strictEqual(m.tapeContents(blocks, []).entry, 0x5CD0);
  });

  // The same questions put to the Python: loader.py, and the emulator's own
  // scripts/tape_rom.py and scripts/tape_screen.py. Skipped, not failed, when
  // there is no Python that can import them (loader.py needs numpy).
  const python = pythonAnswers();
  if (!python) {
    console.log('skip no Python that can import loader.py and scripts/tape_*.py');
  } else {
    test('loader.py and the model agree on the loader\'s size and whereabouts', () => {
      assert.strictEqual(python.constants.LOADER_SIZE, m.LOADER_SIZE);
      assert.strictEqual(python.constants.LOADER_DEFAULT, m.LOADER_DEFAULT);
      assert.deepStrictEqual(python.constants.LIVE_STACK, m.LIVE_STACK);
      assert.deepStrictEqual(python.constants.BASIC_STACK, m.BASIC_STACK);
      for (const name of ['STACK_DEFAULT', 'STACK_SP', 'STACK_DEPTH', 'BASIC_LOADER', 'ROM_STACK']) {
        assert.deepStrictEqual(python.constants[name], m[name], name);
      }
      assert.deepStrictEqual(python.constants.SCREEN_MEMORY, m.SCREEN_MEMORY);
      assert.strictEqual(python.constants.PROG, m.PROG);
      assert.strictEqual(python.constants.ROM_HEADROOM, m.ROM_HEADROOM);
    });

    test('the timings are what the Python\'s pulses add up to', () => {
      const tap = fs.readFileSync(path.join(LOADER, 'loader.tap'));
      assert.ok(Math.abs(m.romTapeSeconds(tap) - python.romSeconds) < 1e-6);
      const runs = m.patternRuns(screen, JETMAN);
      assert.ok(Math.abs(m.fastSeconds(m.totalBits(runs), [1000, 3]) - python.fastSeconds) < 1e-6);
    });

    test('a standard ROM tape is the same .tap from either side, byte for byte', () => {
      const sample = romSample();
      const mine = m.romTap(sample.tape, screen, sample.data.map((d) => Uint8Array.from(d)), 'sample');
      assert.deepStrictEqual(Array.from(mine), python.romTap);
      assert.ok(Math.abs(m.romTapeSeconds(mine) - python.romTapSeconds) < 1e-6);
    });

    test('checkTape says word for word what the Python says, for both schemes', () => {
      checkCases().forEach((c, i) => {
        assert.deepStrictEqual(m.checkTape(c.tape, c.lengths, c.screen), python.checks[i],
                               'case ' + i + ': ' + JSON.stringify(c.tape));
      });
    });

    test('the builder finds the same loading screen the designer shows', () => {
      const info = require('../program_info');
      for (const [file, digest] of Object.entries(python.screens)) {
        const bytes = fs.readFileSync(path.join(ROOT, file));
        let mine = null;
        if (/\.scr$/i.test(file)) {
          mine = Buffer.alloc(6912, 0x38);
          bytes.copy(mine, 0, 0, Math.min(bytes.length, 6912));
        } else {
          const found = info.programScreen(path.basename(file), bytes);
          mine = found ? Buffer.from(found.screen) : null;
        }
        const hash = mine ? require('crypto').createHash('md5').update(mine).digest('hex') : 'none';
        assert.strictEqual(hash, digest, file);
      }
    });
  }
}

// A standard ROM tape to build on both sides.
function romSample() {
  return {
    tape: { scheme: 'rom', entry: 0x8000, stack: 0xBFFF,
            blocks: [{ name: 'code', address: 0x8000 }, { name: 'data', address: 0xC000 }] },
    data: [[0x18, 0xFE, 0x00], Array.from({ length: 300 }, (_, i) => (i * 7) & 0xFF)]
  };
}

// Tapes for both checkers, covering every rule each scheme has -- a function
// so it is there before the tests above it run.
function checkCases() {
  const fast = (fields) => Object.assign({ scheme: 'zx-tape-loader', loaderAddress: null, entry: 0x8000,
    blocks: [{ name: 'a', address: 0x8000 }] }, fields);
  const rom = (fields) => Object.assign({ scheme: 'rom', entry: 0x8000, blocks: [{ name: 'a', address: 0x8000 }] }, fields);
  return [
    { tape: fast({}), lengths: [100], screen: false },
    { tape: fast({ loaderAddress: 0x7000 }), lengths: [100], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0xFE00 }], entry: 0xFE00 }), lengths: [1000], screen: false },
    { tape: fast({ loaderAddress: 0x9000, blocks: [{ name: 'a', address: 0xFE00 }], entry: 0xFE00 }), lengths: [512], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0x5F00 }], entry: 0x5F00 }), lengths: [100], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0x5F2C }], entry: 0x5F2C }), lengths: [10], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0x5000 }], entry: 0x5000 }), lengths: [100], screen: true },
    { tape: fast({ blocks: [{ name: 'a', address: 0x3F00 }], entry: 0x3F00 }), lengths: [0x200], screen: false },
    { tape: fast({ entry: null }), lengths: [100], screen: false },
    { tape: fast({ entry: 0x0010 }), lengths: [100], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0x8000 }, { name: 'b', address: 0x8010 }] }), lengths: [100, 10], screen: false },
    { tape: fast({ stack: 0xFE4D, blocks: [{ name: 'a', address: 0x5E00 }], entry: 0x5E00 }), lengths: [31000], screen: false },
    { tape: fast({ stack: 0xFE4D, blocks: [{ name: 'a', address: 0xFE00 }], entry: 0xFE00 }), lengths: [0x40], screen: false },
    { tape: fast({ stack: 0x5F00 }), lengths: [100], screen: false },
    { tape: fast({ stack: 0xFE4E }), lengths: [100], screen: false },
    { tape: fast({ stack: 0x9000, loaderAddress: 0x9000 }), lengths: [100], screen: false },
    { tape: fast({ blocks: [{ name: 'a', address: 0x5C80 }], entry: 0x5C80 }), lengths: [16], screen: false },
    { tape: rom({}), lengths: [100], screen: true },
    { tape: rom({ blocks: [{ name: 'a', address: 0x5D00 }], entry: 0x5D00 }), lengths: [100], screen: false },
    { tape: rom({ blocks: [{ name: 'a', address: 0x5000 }, { name: 'b', address: 0x8000 }] }), lengths: [100, 10], screen: true },
    { tape: rom({ blocks: [{ name: 'a', address: 0xFF00 }], entry: 0xFF00 }), lengths: [512], screen: false },
    { tape: rom({ entry: null }), lengths: [100], screen: false },
    { tape: rom({ blocks: [{ name: 'a', address: 0x3F00 }], entry: 0x3F00 }), lengths: [0x200], screen: false },
    { tape: rom({ stack: 0x8080 }), lengths: [100], screen: false },
    { tape: rom({ stack: 0x8100 }), lengths: [0x100], screen: false },
    { tape: rom({ stack: 0x5D00 }), lengths: [100], screen: false }
  ];
}

// Put the same questions to the Python in one run.
function pythonAnswers() {
  const script = [
    'import hashlib, json, os, sys',
    'root, loader_dir = sys.argv[1], sys.argv[2]',
    'sys.path.insert(0, os.path.join(root, "scripts"))',
    'sys.path.insert(0, loader_dir)',
    'import loader, tape_rom, tape_screen',
    'ask = json.loads(sys.stdin.read())',
    'gen = loader.TapeGenerator()',
    'loader.encode_tap_file(gen, os.path.join(loader_dir, "loader.tap"))',
    'fast = loader.TapeGenerator()',
    'fast.fast_leader()',
    'jetman = open(os.path.join(loader_dir, "LunarJetman.scr"), "rb").read()',
    'for x, y, w, h in ask["regions"]: loader.gen_block(fast, jetman, x, y, w, h)',
    'fast.end_screen()',
    'for length in (1000, 3):',
    '    fast.mem_header(0x8000, length)',
    '    [fast.dme_byte(0) for _ in range(length)]',
    'fast.end_blocks(0x8000)',
    'def design(t, lengths, screen):',
    '    return {"loader": t.get("loaderAddress"), "stack": t.get("stack"), "entry": t["entry"],',
    '            "screen": {"data": jetman[:6912], "regions": []} if screen else None,',
    '            "blocks": [{"name": b["name"], "address": b["address"], "data": bytes(n)}',
    '                       for b, n in zip(t["blocks"], lengths)]}',
    'checks = []',
    'for case in ask["checks"]:',
    '    d = design(case["tape"], case["lengths"], case["screen"])',
    '    if case["tape"]["scheme"] == "rom":',
    '        e, w = tape_rom.check(d)',
    '    else:',
    '        at = loader.LOADER_DEFAULT if d["loader"] is None else d["loader"]',
    '        e, w = loader.check_design(d, at, loader.STACK_DEFAULT if d["stack"] is None else d["stack"])',
    '    checks.append({"errors": e, "warnings": w})',
    's = ask["rom"]',
    'rom_design = {"entry": s["tape"]["entry"], "stack": s["tape"].get("stack"), "screen": {"data": jetman[:6912]},',
    '              "blocks": [{"name": b["name"], "address": b["address"], "data": bytes(d)}',
    '                         for b, d in zip(s["tape"]["blocks"], s["data"])]}',
    'rom_tap = tape_rom.tap(rom_design, "sample")',
    'screens = {}',
    'for f in ask["screens"]:',
    '    try: screens[f] = hashlib.md5(tape_screen.screen_from_file(os.path.join(root, f))).hexdigest()',
    '    except (OSError, ValueError): screens[f] = "none"',
    'print(json.dumps({"constants": {"LOADER_SIZE": loader.LOADER_SIZE, "LOADER_DEFAULT": loader.LOADER_DEFAULT,',
    '    "LIVE_STACK": list(loader.LIVE_STACK), "BASIC_STACK": list(loader.BASIC_STACK),',
    '    "SCREEN_MEMORY": list(loader.SCREEN_MEMORY), "PROG": tape_rom.PROG, "ROM_HEADROOM": tape_rom.ROM_HEADROOM,',
    '    "STACK_DEFAULT": loader.STACK_DEFAULT, "STACK_SP": loader.STACK_SP, "STACK_DEPTH": loader.STACK_DEPTH,',
    '    "BASIC_LOADER": list(loader.BASIC_LOADER), "ROM_STACK": tape_rom.ROM_STACK},',
    '    "romSeconds": sum(gen.pulses) / 3500000, "fastSeconds": sum(fast.pulses) / 3500000,',
    '    "checks": checks, "romTap": list(rom_tap), "romTapSeconds": tape_rom.seconds(rom_tap),',
    '    "screens": screens}))'
  ].join('\n');
  // Pictures in the repo to find a screen in, whichever are present -- the
  // games are not all committed.
  const screens = ['examples/zx-tape-loader/LunarJetman.scr', 'snapshots/Chronos.sna', 'snapshots/Pentagram.sna',
                   'snapshots/hobbit-v1.2-loaded.z80', 'tapes/Pentagram.tzx', 'tapes/HobbitV1.2.tzx',
                   'tapes/Cobra.tzx', 'tapes/loading-test.tap']
    .filter((f) => fs.existsSync(path.join(ROOT, f)));
  const ask = JSON.stringify({ regions: JETMAN.map((r) => [r.x, r.y, r.w, r.h]), checks: checkCases(),
                               rom: romSample(), screens });
  const file = path.join(os.tmpdir(), 'tape_model_test_' + process.pid + '.py');
  fs.writeFileSync(file, script);
  try {
    // The repo's own venv first, as AGENTS.md says -- it is where numpy is.
    const venvs = [path.join(ROOT, '.venv-win', 'Scripts', 'python.exe'), path.join(ROOT, '.venv', 'bin', 'python')];
    for (const exe of venvs.filter((p) => fs.existsSync(p)).concat(['python', 'python3'])) {
      const done = childProcess.spawnSync(exe, [file, ROOT, LOADER], { input: ask, encoding: 'utf8', timeout: 60000 });
      if (done.status === 0) {
        return JSON.parse(done.stdout);
      }
    }
    return null;
  } finally {
    fs.unlinkSync(file);
  }
}

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
