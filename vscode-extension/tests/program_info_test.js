// Tests for program_info.js -- what a snapshot or tape opened in VS Code is.
// Plain Node, no vscode API and no test framework:
//
//   node vscode-extension/tests/program_info_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/program_info_test.js)
//
// The last tests read the snapshots and tapes committed in this repo, when
// they are there.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const p = require('../program_info');

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

function z80Header(extra, hardware, pc) {
  const bytes = new Uint8Array(32 + extra + 10);
  bytes[30] = extra & 0xFF;
  bytes[32] = pc & 0xFF;
  bytes[33] = pc >> 8;
  bytes[34] = hardware;
  return bytes;
}

test('text and binaries are told apart', () => {
  assert.strictEqual(p.looksLikeText(Buffer.from('start:\tld a,1\r\n\tret\n')), true);
  assert.strictEqual(p.looksLikeText(Uint8Array.from([0x3E, 0x01, 0x00, 0xC9])), false);
  assert.strictEqual(p.looksLikeText(Uint8Array.from([0x3E, 0x01, 0x02, 0x03, 0x04, 0xC9])), false);
});

test('a .sna is 48K or 128K by its size', () => {
  assert.strictEqual(p.describeProgram('a.sna', new Uint8Array(49179)).model, '48K');
  const big = new Uint8Array(131103);
  big[49179] = 0x34;
  big[49180] = 0x12;
  const d = p.describeProgram('a.SNA', big);
  assert.deepStrictEqual([d.model, d.needs128, d.details], ['128K', true, ['PC $1234']]);
  assert.strictEqual(p.describeProgram('a.sna', new Uint8Array(100)).kind, 'unknown');
});

test('a .z80 says its version and machine', () => {
  const v1 = new Uint8Array(40);
  v1[6] = 0x00;
  v1[7] = 0x80;
  v1[12] = 0x20;
  assert.deepStrictEqual(p.describeProgram('g.z80', v1),
    { kind: 'snapshot', format: '.z80 version 1', model: '48K', needs128: false,
      details: ['PC $8000', 'compressed'] });
  const v2 = p.describeProgram('g.z80', z80Header(23, 3, 0x6000));
  assert.deepStrictEqual([v2.format, v2.model, v2.needs128, v2.details], ['.z80 version 2', '128K', true, ['PC $6000']]);
  const v3 = p.describeProgram('g.z80', z80Header(54, 0, 0x5CCB));
  assert.deepStrictEqual([v3.format, v3.model, v3.needs128], ['.z80 version 3', '48K', false]);
  assert.strictEqual(p.describeProgram('g.z80', z80Header(55, 12, 1)).model, '+2');
  assert.strictEqual(p.describeProgram('g.z80', z80Header(55, 12, 1)).needs128, true);
  assert.strictEqual(p.describeProgram('g.z80', z80Header(40, 0, 1)).kind, 'unknown');
});

test('a .tap lists its blocks and the files its headers name', () => {
  const header = [19, 0, 0x00, 0x00, ...Buffer.from('HELLO     '), 10, 0, 0, 0, 10, 0, 0x55];
  const data = [12, 0, 0xFF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x0B];
  const d = p.describeProgram('t.tap', Uint8Array.from(header.concat(data)));
  assert.deepStrictEqual(d.details, ['2 blocks', 'Program: HELLO']);
  assert.strictEqual(p.describeProgram('t.tap', Uint8Array.from([50, 0, 1, 2])).kind, 'unknown');
  const trailing = p.describeProgram('t.tap', Uint8Array.from(header.concat(data, [9, 9, 9])));
  assert.deepStrictEqual(trailing.details, ['2 blocks', 'Program: HELLO', '3 stray bytes at the end, ignored']);
});

test('a .tzx is recognised by its signature', () => {
  const tzx = Uint8Array.from([...Buffer.from('ZXTape!'), 0x1A, 1, 20, 0x10]);
  assert.deepStrictEqual(p.describeProgram('t.tzx', tzx.subarray(0, 10)),
    { kind: 'tape', format: '.tzx version 1.20', model: '48K', needs128: false, details: ['0 data blocks'] });
  assert.strictEqual(p.describeProgram('t.tzx', Buffer.from('not a tape')).kind, 'unknown');
  assert.strictEqual(p.describeProgram('t.bin', new Uint8Array(10)).kind, 'unknown');
});

// A .tzx from its blocks, each an array of bytes starting with its ID.
function tzxOf(...blocks) {
  return Uint8Array.from([...Buffer.from('ZXTape!'), 0x1A, 1, 20, ...blocks.flat()]);
}
function standardBlock(flag, data) {
  const len = data.length + 2;
  return [0x10, 0xE8, 0x03, len & 0xFF, len >> 8, flag, ...data, 0];
}
function turboBlock(flag, data) {
  const len = data.length + 2;
  return [0x11, ...new Array(15).fill(1), len & 0xFF, len >> 8, 0, flag, ...data, 0];
}
function archiveInfo(fields) {
  const body = [fields.length];
  for (const [id, text] of fields) {
    body.push(id, text.length, ...Buffer.from(text));
  }
  return [0x32, body.length & 0xFF, body.length >> 8, ...body];
}
function groupStart(name) {
  return [0x21, name.length, ...Buffer.from(name)];
}

test('a .tzx names its loader: from its archive info, its groups, or its blocks', () => {
  const header = [0, ...Buffer.from('KNIGHT    '), 10, 0, 0, 0, 10, 0];
  const plain = p.describeProgram('t.tzx', tzxOf(standardBlock(0, header), standardBlock(0xFF, [1, 2, 3])));
  assert.deepStrictEqual(plain.details,
    ['2 data blocks', 'Program: KNIGHT', 'Loader: standard (every block at the ROM\'s timings)']);

  const turbo = p.describeProgram('t.tzx', tzxOf(standardBlock(0, header), turboBlock(0xFF, [1, 2, 3])));
  assert.strictEqual(turbo.details[2], 'Loader: custom (the tape doesn\'t name it)');

  const grouped = p.describeProgram('t.tzx', tzxOf(standardBlock(0, header), groupStart('SpeedLock 1 Block 1'),
    turboBlock(0xFF, [1]), [0x22], groupStart('SpeedLock 1 Block 2'), turboBlock(0xFF, [2]), [0x22]));
  assert.deepStrictEqual(grouped.details, ['3 data blocks', 'Program: KNIGHT', 'Loader: SpeedLock 1']);

  // A group that is not "<loader> Block <n>" is not taken for a loader.
  const side = p.describeProgram('t.tzx', tzxOf(groupStart('Side A'), turboBlock(0xFF, [1]), [0x22]));
  assert.strictEqual(side.details[1], 'Loader: custom (the tape doesn\'t name it)');

  // The archive info's own loader field wins over the groups.
  const labelled = p.describeProgram('t.tzx', tzxOf(
    archiveInfo([[0x00, 'Knight Lore'], [0x01, 'Ultimate'], [0x03, '1984'], [0x07, 'Speedlock 1']]),
    groupStart('SpeedLock 1 Block 1'), turboBlock(0xFF, [1]), [0x22]));
  assert.deepStrictEqual(labelled.details, ['Knight Lore, Ultimate, 1984', '1 data block', 'Loader: Speedlock 1']);
});

test('the ROM is picked by size', () => {
  const sizes = { 'a.rom': 16384, 'b.rom': 32768 };
  assert.strictEqual(p.pickRom(['a.rom', 'b.rom'], false, (f) => sizes[f]), 'a.rom');
  assert.strictEqual(p.pickRom(['a.rom', 'b.rom'], true, (f) => sizes[f]), 'b.rom');
  assert.strictEqual(p.pickRom(['a.rom'], true, (f) => sizes[f]), null);
});

test('the launch configuration loads the program the right way', () => {
  const snap = p.launchConfigFor('/g/x.z80', 'x.z80', { kind: 'snapshot', needs128: true }, '/r/128.rom',
                                 { sld: '/g/x.sld', asm: '/g/x.asm' }, false);
  assert.deepStrictEqual(snap, {
    type: 'zxspectrum', request: 'launch', name: 'ZX Spectrum: x.z80', stopOnEntry: false,
    rom: '/r/128.rom', machine: '128', snapshot: '/g/x.z80', sld: '/g/x.sld', asm: '/g/x.asm'
  });
  const tape = p.launchConfigFor('/g/t.tzx', 't.tzx', { kind: 'tape', needs128: false }, '/r/48.rom', null, true);
  assert.deepStrictEqual(tape, {
    type: 'zxspectrum', request: 'launch', name: 'ZX Spectrum: t.tzx', stopOnEntry: true,
    rom: '/r/48.rom', tape: '/g/t.tzx', tapeAutoStart: true
  });
  assert.deepStrictEqual(p.debugInfoCandidates('/g/prog.sna'),
    { sld: '/g/prog.sld', asm: ['/g/prog.asm', '/g/prog.s', '/g/prog.a80',
                                '/prog.asm', '/prog.s', '/prog.a80'] });
});

test('a build\'s output/ folder finds the source one level up', () => {
  // examples/filmation: output/knightlore.z80 and .sld, knightlore.s above.
  const c = p.debugInfoCandidates('C:\\g\\knightlore\\output\\knightlore.z80');
  assert.strictEqual(c.sld, 'C:\\g\\knightlore\\output\\knightlore.sld');
  assert.deepStrictEqual(c.asm.slice(3),
    ['C:\\g\\knightlore\\knightlore.asm', 'C:\\g\\knightlore\\knightlore.s', 'C:\\g\\knightlore\\knightlore.a80']);
  assert.deepStrictEqual(p.debugInfoCandidates('prog.sna').asm, ['prog.asm', 'prog.s', 'prog.a80']);
});

const FILMATION = path.join(__dirname, '..', '..', 'examples', 'filmation', 'knightlore');
if (fs.existsSync(path.join(FILMATION, 'output', 'knightlore.sld'))) {
  test('the Filmation build is found from its snapshot', () => {
    const c = p.debugInfoCandidates(path.join(FILMATION, 'output', 'knightlore.z80'));
    assert.ok(fs.existsSync(c.sld), c.sld);
    assert.ok(c.asm.some((f) => fs.existsSync(f)), c.asm.join(', '));
  });
}

// ---- the screen ----

// A 6912-byte screen whose bytes say where they are, so a wrong offset shows.
function screenPattern() {
  return Uint8Array.from({ length: 6912 }, (_, i) => (i * 7 + 3) & 0xFF);
}

function packZ80(data) {
  const out = [];
  for (let i = 0; i < data.length;) {
    let run = 1;
    while (i + run < data.length && data[i + run] === data[i] && run < 255) run++;
    if (run >= 5 || (data[i] === 0xED && run >= 2)) {
      out.push(0xED, 0xED, run, data[i]);
      i += run;
    } else {
      out.push(data[i]);
      i++;
    }
  }
  return Uint8Array.from(out);
}

test('.z80 compression unpacks', () => {
  const out = new Uint8Array(8);
  assert.strictEqual(p.unpackZ80(Uint8Array.from([1, 0xED, 0xED, 5, 9, 2, 0xED, 3]), 0, 8, out), 8);
  assert.deepStrictEqual(Array.from(out), [1, 9, 9, 9, 9, 9, 2, 0xED]);
});

test('a .sna\'s screen and border', () => {
  const sna = new Uint8Array(49179);
  sna[26] = 5;
  sna.set(screenPattern(), 27);
  const r = p.programScreen('x.sna', sna);
  assert.deepStrictEqual([r.border, r.source], [5, 'the snapshot']);
  assert.deepStrictEqual(r.screen, screenPattern());
});

test('a compressed version 1 .z80\'s screen', () => {
  const ram = new Uint8Array(49152);
  ram.set(screenPattern(), 0);
  const body = packZ80(ram);
  const z = new Uint8Array(30 + body.length + 4);
  z[6] = 0x00; z[7] = 0x80;          // PC: version 1
  z[12] = 0x20 | (3 << 1);           // compressed, border 3
  z.set(body, 30);
  z.set([0, 0xED, 0xED, 0], 30 + body.length);
  const r = p.programScreen('x.z80', z);
  assert.strictEqual(r.border, 3);
  assert.deepStrictEqual(r.screen, screenPattern());
});

test('a version 3 .z80\'s screen is page 8', () => {
  const page8 = new Uint8Array(16384);
  page8.set(screenPattern(), 0);
  const packed = packZ80(page8);
  const other = Uint8Array.from([0xED, 0xED, 255, 1, 0xED, 0xED, 255, 1]);
  const header = new Uint8Array(30 + 2 + 54);
  header[30] = 54;
  header[34] = 0;
  const block = (page, data) => Uint8Array.from([data.length & 0xFF, data.length >> 8, page, ...data]);
  const file = Uint8Array.from([...header, ...block(4, other), ...block(8, packed), ...block(5, other)]);
  assert.deepStrictEqual(p.programScreen('x.z80', file).screen, screenPattern());
});

test('a tape\'s SCREEN$ block, and a headerless one', () => {
  const tapBlock = (flag, data) => {
    const len = data.length + 2;
    return [len & 0xFF, len >> 8, flag, ...data, 0];
  };
  const header = [3, ...Buffer.from('screen    '), 0x00, 0x1B, 0x00, 0x40, 0, 0];
  const tap = Uint8Array.from([...tapBlock(0, header), ...tapBlock(0xFF, screenPattern())]);
  const r = p.programScreen('x.tap', tap);
  assert.strictEqual(r.source, 'the tape\'s loading screen');
  assert.deepStrictEqual(r.screen, screenPattern());

  // A custom loader's block: a flag and 6912 bytes, with no checksum. Its
  // attributes are ink and paper with no FLASH, as a real screen's are.
  const plain = screenPattern();
  plain.fill(0x38, 6144, 6912);
  plain[6144] = 0xB8;
  const bareTzx = (screen) => Uint8Array.from([...Buffer.from('ZXTape!'), 0x1A, 1, 20,
    0x10, 0, 0, 0x01, 0x1B, 0x77, ...screen]);
  const t = p.programScreen('x.tzx', bareTzx(plain));
  assert.deepStrictEqual(t && [t.screen, t.source], [plain, 'the tape\'s loading screen']);

  // Knight Lore's loader holds each attribute rotated right a bit, so an odd
  // ink comes out as FLASH: $39 (white paper, blue ink) is $9C on the tape,
  // and $56 (bright red paper, yellow ink) is $2B.
  const rotated = Uint8Array.from(plain);
  rotated.fill(0x9C, 6144, 6912);
  rotated[6145] = 0x2B;
  const expected = Uint8Array.from(plain);
  expected.fill(0x39, 6144, 6912);
  expected[6145] = 0x56;
  const r2 = p.programScreen('x.tzx', bareTzx(rotated));
  assert.deepStrictEqual(r2 && [r2.screen, r2.source],
    [expected, 'the tape\'s loading screen, its attributes rotated back']);

  // Bytes that are not attributes either way -- FLASH on half the cells as
  // they are and rotated -- are no picture rather than a garbled one.
  assert.strictEqual(p.programScreen('x.tzx', bareTzx(screenPattern())), null);

  assert.strictEqual(p.programScreen('x.tap', Uint8Array.from(tapBlock(0xFF, [1, 2, 3]))), null);
});

const REPO = path.join(__dirname, '..', '..');
function real(rel, check) {
  const file = path.join(REPO, rel);
  if (!fs.existsSync(file)) {
    console.log('skip ' + rel + ' (not here)');
    return;
  }
  test('reads ' + rel, () => check(p.describeProgram(path.basename(file), fs.readFileSync(file))));
}

real('examples/border_rainbow/test.sna', (d) => assert.deepStrictEqual([d.kind, d.model], ['snapshot', '48K']));
real('examples/filmation/knightlore/output/knightlore.z80', (d) => assert.strictEqual(d.kind, 'snapshot'));
real('tapes/loading-test.tap', (d) => {
  assert.strictEqual(d.kind, 'tape');
  assert.ok(/blocks?$/.test(d.details[0]), d.details[0]);
});
real('tapes/loading-test.tzx', (d) => {
  assert.strictEqual(d.kind, 'tape');
  assert.strictEqual(d.details[d.details.length - 1], 'Loader: standard (every block at the ROM\'s timings)');
});
real('examples/hello_rom_call/test.asm', () => {
  assert.strictEqual(p.looksLikeText(fs.readFileSync(path.join(REPO, 'examples/hello_rom_call/test.asm'))), true);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
