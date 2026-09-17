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
});

test('a .tzx is recognised by its signature', () => {
  const tzx = Uint8Array.from([...Buffer.from('ZXTape!'), 0x1A, 1, 20, 0x10]);
  assert.deepStrictEqual(p.describeProgram('t.tzx', tzx),
    { kind: 'tape', format: '.tzx version 1.20', model: '48K', needs128: false, details: [] });
  assert.strictEqual(p.describeProgram('t.tzx', Buffer.from('not a tape')).kind, 'unknown');
  assert.strictEqual(p.describeProgram('t.bin', new Uint8Array(10)).kind, 'unknown');
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
    { sld: '/g/prog.sld', asm: ['/g/prog.asm', '/g/prog.s', '/g/prog.a80'] });
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
real('tapes/loading-test.tzx', (d) => assert.strictEqual(d.kind, 'tape'));
real('examples/hello_rom_call/test.asm', () => {
  assert.strictEqual(p.looksLikeText(fs.readFileSync(path.join(REPO, 'examples/hello_rom_call/test.asm'))), true);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
