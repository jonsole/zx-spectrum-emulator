// Tests for graphics_model.js -- the graphics panel's decoding and its sprite
// sheet export. Plain Node, no vscode API and no test framework:
//
//   node vscode-extension/tests/graphics_model_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/graphics_model_test.js)

const assert = require('assert');
const m = require('../graphics_model');

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

function sprite(id, fields) {
  const entry = m.withDefaults(Object.assign({ format: 'sprite' }, fields));
  entry.id = id;
  return entry;
}

// The bytes of every DEFB line, the way the extension's selection parser
// reads them -- which is what "Grab selection" on the exported source does.
function assembled(source) {
  const bytes = [];
  for (const line of source.split('\n')) {
    const code = line.replace(/;.*$/, '');
    const match = /\bDEFB\b(.*)$/.exec(code);
    if (!match) continue;
    for (const token of match[1].split(',')) {
      const t = token.trim();
      bytes.push(t[0] === '%' ? parseInt(t.slice(1), 2) : parseInt(t.slice(1), 16));
    }
  }
  return Uint8Array.from(bytes);
}

function labels(source) {
  return source.split('\n').filter((l) => /^[A-Za-z_]\w*:$/.test(l)).map((l) => l.slice(0, -1));
}

function memoryOrigin(address) {
  return { kind: 'memory', address, label: 'memory $' + address.toString(16) };
}

test('names are valid labels', () => {
  assert.strictEqual(m.sanitizeLabel('knight walk'), 'knight_walk');
  assert.strictEqual(m.sanitizeLabel('sprite_000+4'), 'sprite_000_4');
  assert.strictEqual(m.sanitizeLabel('3d-head'), '_3d_head');
  assert.strictEqual(m.sanitizeLabel('  ...  '), '');
});

test('an unnamed sprite is named after its symbol, its file, or its number', () => {
  const names = m.assignNames([
    sprite(1, { source: 'memory', address: 'sprite_000' }),
    sprite(2, { source: 'memory', address: '$8000' }),
    sprite(3, { source: 'file', file: 'C:\\x\\sprite data.bin', offset: 120 }),
    sprite(4, { source: 'selection', name: 'hero' })
  ]);
  assert.deepStrictEqual([...names.values()], ['sprite_000', 'sprite2', 'sprite_data_120', 'hero']);
});

test('names never collide with another sprite\'s frame labels', () => {
  const names = m.assignNames([
    sprite(1, { name: 'ball', count: 2 }),
    sprite(2, { name: 'ball_1', count: 1 }),
    sprite(3, { name: 'ball', count: 1 })
  ]);
  // ball writes ball, ball_0 and ball_1, so neither of the others may use those.
  assert.deepStrictEqual([...names.values()], ['ball', 'ball_1_2', 'ball_2']);
});

test('font frames are named by character code', () => {
  const font = sprite(1, { format: 'font', width: 1, height: 8, count: 3, first: 65 });
  assert.strictEqual(m.frameName(font, 'font', 0), 'font_65');
  assert.strictEqual(m.frameName(font, 'font', 2), 'font_67');
  assert.strictEqual(m.frameName(sprite(2, { count: 1 }), 'solo', 0), 'solo');
});

test('items past the end of the data are left out', () => {
  const entry = sprite(1, { width: 1, height: 2, count: 4, header: 1 });
  // 3 bytes an item: 7 bytes covers item 0, item 1, and the header of item 2.
  assert.deepStrictEqual(m.presentItems(entry, new Uint8Array(7)), [0, 1]);
  assert.deepStrictEqual(m.presentItems(entry, new Uint8Array(0)), []);
});

test('the sheet packs sprites of different sizes in order, a pixel apart', () => {
  const a = sprite(1, { width: 2, height: 16, count: 4, columns: 2 });
  const b = sprite(2, { width: 3, height: 24, count: 1 });
  const c = sprite(3, { width: 1, height: 8, count: 2 });
  const bytes = new Map([[1, new Uint8Array(128)], [2, new Uint8Array(72)], [3, new Uint8Array(0)]]);
  const names = m.assignNames([a, b, c]);
  const pack = m.packSheet([a, b, c], bytes, names);
  assert.deepStrictEqual(pack.skipped, [3]);
  assert.deepStrictEqual(pack.frames.map((f) => [f.name, f.x, f.y, f.w, f.h]), [
    ['sprite1_0', 0, 0, 16, 16],
    ['sprite1_1', 17, 0, 16, 16],
    ['sprite1_2', 0, 17, 16, 16],
    ['sprite1_3', 17, 17, 16, 16],
    ['sprite2', 34, 0, 24, 24]
  ]);
  assert.strictEqual(pack.width, 58);
  assert.strictEqual(pack.height, 33);
});

test('a block that would pass the wrap width starts a new shelf', () => {
  const wide = sprite(1, { width: 40, height: 10, count: 1 });  // 320 pixels
  const next = sprite(2, { width: 40, height: 4, count: 1 });
  const bytes = new Map([[1, new Uint8Array(400)], [2, new Uint8Array(160)]]);
  const pack = m.packSheet([wide, next], bytes, m.assignNames([wide, next]));
  assert.deepStrictEqual(pack.frames.map((f) => [f.x, f.y]), [[0, 0], [0, 11]]);
  assert.strictEqual(pack.width, 320);
  assert.strictEqual(pack.height, 15);
});

test('the picture is at one pixel per pixel, masked pixels transparent', () => {
  // One byte wide, one row, mask then data: mask $F0 hides the left half.
  const entry = sprite(1, { width: 1, height: 1, count: 1, interleave: 'md', ink: 2, paper: 7 });
  const bytes = new Map([[1, Uint8Array.from([0xF0, 0x0C])]]);
  const pack = m.packSheet([entry], bytes, m.assignNames([entry]));
  const rgba = m.renderSheet([entry], bytes, pack);
  assert.strictEqual(rgba.length, 8 * 4);
  const alpha = [];
  const colour = [];
  for (let x = 0; x < 8; x++) {
    alpha.push(rgba[x * 4 + 3]);
    colour.push(rgba[x * 4]);
  }
  assert.deepStrictEqual(alpha, [0, 0, 0, 0, 255, 255, 255, 255]);
  // Data $0C = %00001100: pixels 4 and 5 are ink (red), 6 and 7 paper
  // (white). Both have 192 red, so green is what tells them apart.
  const green = [];
  for (let x = 4; x < 8; x++) green.push(rgba[x * 4 + 1]);
  assert.deepStrictEqual(green, [0, 0, 192, 192]);
  assert.deepStrictEqual(colour.slice(4), [192, 192, 192, 192]);
});

test('a screen reads its colours from the attributes', () => {
  const entry = sprite(1, { format: 'screen' });
  const bytes = new Uint8Array(6912);
  bytes[0] = 0x80;               // top-left pixel set
  bytes[6144] = 0x40 | (1 << 3) | 2;  // bright, paper blue, ink red
  const out = new Uint8ClampedArray(256 * 192 * 4);
  assert.strictEqual(m.renderItem(entry, bytes, 0, out), false);
  assert.deepStrictEqual(Array.from(out.subarray(0, 4)), [255, 0, 0, 255]);
  assert.deepStrictEqual(Array.from(out.subarray(4, 8)), [0, 0, 255, 255]);
});

test('the atlas is a TexturePacker hash with the sprites under meta.zx', () => {
  const a = sprite(1, { name: 'walk', source: 'memory', address: 'walk_tab',
                        width: 1, height: 2, count: 2, header: 1 });
  const bytes = new Map([[1, Uint8Array.from([9, 1, 2, 8, 3, 4])]]);
  const origins = new Map([[1, memoryOrigin(0x8000)]]);
  const names = m.assignNames([a]);
  const pack = m.packSheet([a], bytes, names);
  const atlas = m.buildAtlas([a], bytes, origins, names, pack, { image: 'walk.png' });
  assert.deepStrictEqual(Object.keys(atlas.frames), ['walk_0', 'walk_1']);
  const f = atlas.frames.walk_1;
  assert.deepStrictEqual(f.frame, { x: 9, y: 0, w: 8, h: 2 });
  assert.deepStrictEqual(f.sourceSize, { w: 8, h: 2 });
  assert.deepStrictEqual(f.zx, { sprite: 'walk', item: 1, offset: 3, address: 0x8003 });
  assert.strictEqual(atlas.meta.image, 'walk.png');
  assert.deepStrictEqual(atlas.meta.size, { w: 17, h: 2 });
  const s = atlas.meta.zx.sprites[0];
  assert.strictEqual(s.address, 'walk_tab');
  assert.strictEqual(s.resolvedAddress, 0x8000);
  assert.strictEqual(s.file, undefined);
  assert.deepStrictEqual(s.frames, ['walk_0', 'walk_1']);
  assert.deepStrictEqual(Array.from(m.fromBase64(s.bytes)), [9, 1, 2, 8, 3, 4]);
  // It is plain JSON: nothing in it is lost on the way to a file.
  assert.deepStrictEqual(JSON.parse(JSON.stringify(atlas)), atlas);
});

test('the assembler source assembles back to the same bytes', () => {
  const a = sprite(1, { name: 'guard', width: 2, height: 3, count: 2, header: 2,
                        interleave: 'md', bottomUp: true });
  const b = sprite(2, { name: 'glyphs', format: 'font', width: 1, height: 8, count: 2, first: 65 });
  const c = sprite(3, { name: 'title', format: 'screen' });
  const bytesA = Uint8Array.from({ length: 2 * (2 + 4 * 3) }, (_, i) => (i * 37 + 5) & 0xFF);
  const bytesB = Uint8Array.from({ length: 16 }, (_, i) => i * 11);
  const bytesC = Uint8Array.from({ length: 6912 }, (_, i) => i & 0xFF);
  const bytes = new Map([[1, bytesA], [2, bytesB], [3, bytesC]]);
  const entries = [a, b, c];
  const names = m.assignNames(entries);
  const pack = m.packSheet(entries, bytes, names);
  const asm = m.buildAsm(entries, bytes, new Map(), names, pack,
                         { image: 'set.png', atlas: 'set.json' });
  const all = new Uint8Array(bytesA.length + bytesB.length + bytesC.length);
  all.set(bytesA, 0);
  all.set(bytesB, bytesA.length);
  all.set(bytesC, bytesA.length + bytesB.length);
  assert.deepStrictEqual(assembled(asm), all);
  assert.deepStrictEqual(labels(asm), ['guard', 'guard_0', 'guard_1', 'glyphs', 'glyphs_65',
                                       'glyphs_66', 'title', 'title_bitmap', 'title_attrs']);
  assert.ok(asm.includes('set.png'));
  assert.ok(asm.includes("; 65 'A'"));
});

test('the row pictures follow the flip and the mask', () => {
  // One byte wide, two rows, data then mask, bottom row first.
  const entry = sprite(1, { name: 'm', width: 1, height: 2, count: 1,
                            interleave: 'dm', bottomUp: true });
  // Data row 0 (the bottom row): data $FF, mask $0F -> left half ink, right half clear.
  // Data row 1 (the top row):    data $00, mask $00 -> all paper.
  const bytes = new Map([[1, Uint8Array.from([0xFF, 0x0F, 0x00, 0x00])]]);
  const names = m.assignNames([entry]);
  const pack = m.packSheet([entry], bytes, names);
  const asm = m.buildAsm([entry], bytes, new Map(), names, pack, { image: 'a', atlas: 'b' });
  const rows = asm.split('\n').filter((l) => l.includes('DEFB'));
  assert.ok(rows[0].endsWith('; |####    |'), rows[0]);
  assert.ok(rows[1].endsWith('; |........|'), rows[1]);
});

test('source for data that runs out says so', () => {
  const entry = sprite(1, { name: 'cut', width: 2, height: 3, count: 1 });
  const bytes = new Map([[1, Uint8Array.from([1, 2, 3])]]);
  const names = m.assignNames([entry]);
  const pack = m.packSheet([entry], bytes, names);
  const asm = m.buildAsm([entry], bytes, new Map(), names, pack, { image: 'a', atlas: 'b' });
  assert.deepStrictEqual(Array.from(assembled(asm)), [1, 2, 3]);
  assert.ok(asm.includes('the data ran out here'));
});

test('an exported atlas reads back as the same sprites', () => {
  const entries = [
    sprite(1, { name: 'walk', source: 'memory', address: 'walk_tab', width: 3, height: 5,
                count: 2, columns: 1, interleave: 'dm', invertMask: true, ink: 10, paper: 1 }),
    sprite(2, { name: 'sel', source: 'selection', width: 1, height: 1, count: 1 }),
    sprite(3, { name: 'scr', source: 'file', file: 'art/title.scr', format: 'screen', offset: 4 })
  ];
  const bytes = new Map([[1, new Uint8Array(60).fill(7)], [2, Uint8Array.from([0x81])],
                         [3, new Uint8Array(6144)]]);
  const origins = new Map([[1, memoryOrigin(0x9000)]]);
  const names = m.assignNames(entries);
  const pack = m.packSheet(entries, bytes, names);
  const atlas = JSON.parse(JSON.stringify(m.buildAtlas(entries, bytes, origins, names, pack, { image: 'x.png' })));
  const back = m.readAtlas(atlas);
  assert.deepStrictEqual(back.problems, []);
  assert.strictEqual(back.sprites.length, 3);
  for (let i = 0; i < 3; i++) {
    const want = m.spriteConfig(entries[i]);
    const got = back.sprites[i].cfg;
    for (const key of m.SPRITE_KEYS) {
      if (key === 'file' && want.source !== 'file') continue;
      assert.deepStrictEqual(got[key], want[key], entries[i].name + '.' + key);
    }
    assert.deepStrictEqual(back.sprites[i].bytes, bytes.get(entries[i].id));
  }
  assert.deepStrictEqual(back.sprites[0].origin, { kind: 'memory', address: 0x9000,
                                                   label: 'memory $9000' });
  assert.strictEqual(back.sprites[1].origin.kind, 'import');
});

test('a hand-edited atlas costs the bad fields, not the sheet', () => {
  const back = m.readAtlas({ meta: { zx: { sprites: [
    { name: 'ok thing', source: 'memory', format: 'sprite', width: 900, height: -3,
      count: 'lots', interleave: 'sideways', ink: 99 },
    { name: 'broken', source: 'selection', bytes: '' },
    'not a sprite'
  ] } } });
  assert.strictEqual(back.sprites.length, 2);
  const cfg = back.sprites[0].cfg;
  assert.strictEqual(cfg.name, 'ok_thing');
  assert.strictEqual(cfg.width, 64);
  assert.strictEqual(cfg.height, 1);
  assert.strictEqual(cfg.count, m.DRAFT_DEFAULTS.count);
  assert.strictEqual(cfg.interleave, 'none');
  assert.strictEqual(cfg.ink, 15);
  assert.strictEqual(back.problems.length, 2);
  assert.ok(/carries no bytes/.test(back.problems[0]));
  assert.ok(/not an object/.test(back.problems[1]));
});

// A sheet sprite is the other one whose bytes have to travel with it: it was
// drawn rather than found, so there is no address and no file to fall back on.
test('a sheet sprite with no bytes is a problem too', () => {
  const back = m.readAtlas({ meta: { zx: { sprites: [
    { name: 'drawn', source: 'sheet', bytes: '' }
  ] } } });
  assert.strictEqual(back.sprites[0].cfg.source, 'sheet');
  assert.ok(m.carriesBytes(back.sprites[0].cfg));
  assert.strictEqual(back.problems.length, 1);
  assert.ok(/carries no bytes/.test(back.problems[0]));
  assert.ok(/sheet sprite/.test(back.problems[0]));
});

// The three sources that can be read again are not carriers: a sheet sprite
// must never be asked for from the host.
test('only a selection and a sheet carry their own bytes', () => {
  assert.ok(m.carriesBytes({ source: 'selection' }));
  assert.ok(m.carriesBytes({ source: 'sheet' }));
  assert.ok(!m.carriesBytes({ source: 'memory' }));
  assert.ok(!m.carriesBytes({ source: 'file' }));
});

test('something that is not an export is refused', () => {
  const back = m.readAtlas({ frames: {}, meta: { app: 'TexturePacker' } });
  assert.deepStrictEqual(back.sprites, []);
  assert.strictEqual(back.problems.length, 1);
});

// ---- names and groups ----

test('a new sprite is named after where it came from, numbered when that is taken', () => {
  const none = new Set();
  assert.strictEqual(m.suggestName({ source: 'memory', address: 'guard_tab+8' }, none), 'guard_tab_8');
  assert.strictEqual(m.suggestName({ source: 'memory', address: '$8000' }, none), 'sprite1');
  assert.strictEqual(m.suggestName({ source: 'memory', address: '$8000' }, new Set(['sprite1'])), 'sprite2');
  assert.strictEqual(m.suggestName({ source: 'file', file: '/a/tiles.bin', offset: 16 },
                                   new Set(['tiles_16'])), 'tiles_16_2');
  assert.strictEqual(m.suggestName({ source: 'memory', address: '$3D00', format: 'font' }, none), 'font1');
});

test('a sprite\'s label is prefixed with its group\'s name', () => {
  const walk1 = Object.assign(sprite(1, { name: 'walk' }), { groupName: 'knight' });
  const walk2 = Object.assign(sprite(2, { name: 'walk' }), { groupName: 'guard' });
  const knight = sprite(3, { name: 'knight' });  // same as a group label
  const names = m.assignNames([walk1, walk2, knight]);
  assert.deepStrictEqual([...names.values()], ['knight_walk', 'guard_walk', 'knight_2']);
});

test('each group starts a shelf of its own', () => {
  const a = Object.assign(sprite(1, { name: 'a', width: 1, height: 8, count: 1 }), { groupName: 'g1' });
  const b = Object.assign(sprite(2, { name: 'b', width: 1, height: 8, count: 1 }), { groupName: 'g1' });
  const c = Object.assign(sprite(3, { name: 'c', width: 1, height: 4, count: 1 }), { groupName: 'g2' });
  const bytes = new Map([[1, new Uint8Array(8)], [2, new Uint8Array(8)], [3, new Uint8Array(4)]]);
  const entries = [a, b, c];
  const pack = m.packSheet(entries, bytes, m.assignNames(entries));
  assert.deepStrictEqual(pack.frames.map((f) => [f.name, f.x, f.y]),
                         [['g1_a', 0, 0], ['g1_b', 9, 0], ['g2_c', 0, 9]]);
});

test('the atlas and the source both record the groups', () => {
  const a = Object.assign(sprite(1, { name: 'walk', width: 1, height: 1, count: 2 }), { group: 'x7', groupName: 'knight' });
  const b = Object.assign(sprite(2, { name: 'jump', width: 1, height: 1, count: 1 }), { group: 'x7', groupName: 'knight' });
  const c = sprite(3, { name: 'loose', width: 1, height: 1, count: 1 });
  const entries = [c, a, b];
  const bytes = new Map([[1, Uint8Array.from([1, 2])], [2, Uint8Array.from([3])], [3, Uint8Array.from([4])]]);
  const names = m.assignNames(entries);
  const pack = m.packSheet(entries, bytes, names);
  const atlas = m.buildAtlas(entries, bytes, new Map(), names, pack, { image: 's.png' });
  assert.deepStrictEqual(atlas.meta.zx.groups, [
    { name: 'knight', sprites: ['knight_walk', 'knight_jump'],
      frames: ['knight_walk_0', 'knight_walk_1', 'knight_jump'] }
  ]);
  const walk = atlas.meta.zx.sprites[1];
  assert.strictEqual(walk.group, 'knight');   // the name, never the panel's id
  assert.strictEqual(walk.name, 'walk');
  assert.strictEqual(walk.label, 'knight_walk');
  assert.strictEqual(atlas.frames.knight_walk_1.zx.group, 'knight');
  assert.strictEqual(atlas.meta.zx.sprites[0].group, undefined);

  const asm = m.buildAsm(entries, bytes, new Map(), names, pack, { image: 's.png', atlas: 's.json' });
  assert.deepStrictEqual(labels(asm), ['loose', 'knight', 'knight_walk', 'knight_walk_0',
                                       'knight_walk_1', 'knight_jump']);
  assert.ok(asm.includes('; ==== knight: 2 sprites'));
  assert.deepStrictEqual(Array.from(assembled(asm)), [4, 1, 2, 3]);

  const back = m.readAtlas(JSON.parse(JSON.stringify(atlas)));
  assert.deepStrictEqual(back.groups, ['knight']);
  assert.deepStrictEqual(back.sprites.map((s) => [s.cfg.name, s.cfg.group]),
                         [['loose', ''], ['walk', 'knight'], ['jump', 'knight']]);
});

// ---- pointing into a snapshot ----

test('with no picture the atlas only says where the bytes are', () => {
  const a = sprite(1, { name: 'guard', source: 'memory', address: '$9000', width: 1, height: 2, count: 2 });
  const b = sprite(2, { name: 'blob', source: 'file', file: '/x/knight.sna', offset: 100, width: 1, height: 1, count: 1 });
  const c = sprite(3, { name: 'typed', source: 'selection', width: 1, height: 1, count: 1 });
  const entries = [a, b, c];
  const bytes = new Map([[1, Uint8Array.from([1, 2, 3, 4])], [2, Uint8Array.from([5])], [3, Uint8Array.from([6])]]);
  const origins = new Map([[1, memoryOrigin(0x9000)]]);
  const names = m.assignNames(entries);
  const pack = m.packSheet(entries, bytes, names);
  const atlas = m.buildAtlas(entries, bytes, origins, names, pack, { image: null, reference: true });
  assert.strictEqual(atlas.meta.image, undefined);
  assert.strictEqual(atlas.meta.size, undefined);
  assert.deepStrictEqual(atlas.frames.guard_1, {
    sourceSize: { w: 8, h: 2 }, zx: { sprite: 'guard', item: 1, offset: 2, address: 0x9002 }
  });
  const [ga, gb, gc] = atlas.meta.zx.sprites;
  assert.strictEqual(ga.bytes, undefined);
  assert.strictEqual(ga.length, 4);
  assert.strictEqual(ga.resolvedAddress, 0x9000);
  assert.strictEqual(gb.bytes, undefined);
  assert.strictEqual(gb.file, '/x/knight.sna');
  assert.strictEqual(gb.offset, 100);
  // Nothing else holds a selection's bytes, so it keeps them.
  assert.deepStrictEqual(Array.from(m.fromBase64(gc.bytes)), [6]);

  const back = m.readAtlas(JSON.parse(JSON.stringify(atlas)));
  assert.deepStrictEqual(back.problems, []);
  assert.strictEqual(back.sprites[0].bytes.length, 0);
  assert.strictEqual(back.sprites[1].cfg.offset, 100);

  const asm = m.buildAsm(entries, bytes, origins, names, pack, { image: null, atlas: 'g.json' });
  assert.ok(asm.includes('; g.json says what each one is'));
});

test('sprites point into the saved machine, or into the .sna they came from', () => {
  const rom = sprite(1, { name: 'font', source: 'memory', address: '$3D00', format: 'font',
                          width: 1, height: 8, count: 96 });
  const ram = sprite(2, { name: 'guard', source: 'memory', address: '$9000', width: 1, height: 1, count: 2 });
  const sna = sprite(3, { name: 'head', source: 'file', file: '/g/kl.sna', offset: 19237,
                          width: 1, height: 1, count: 1 });
  const bin = sprite(4, { name: 'tiles', source: 'file', file: '/g/tiles.bin', offset: 5,
                          width: 1, height: 1, count: 1 });
  const entries = [rom, ram, sna, bin];
  const bytes = new Map([[1, new Uint8Array(768).fill(1)], [2, Uint8Array.from([7, 8])],
                         [3, Uint8Array.from([9])], [4, Uint8Array.from([10])]]);
  const origins = new Map([[1, memoryOrigin(0x3D00)], [2, memoryOrigin(0x9000)]]);
  const names = m.assignNames(entries);
  const pack = m.packSheet(entries, bytes, names);
  const atlas = m.buildAtlas(entries, bytes, origins, names, pack, { image: null, reference: true });
  const sprites = atlas.meta.zx.sprites;
  // The ROM is in no snapshot, so the font carries its own bytes.
  assert.strictEqual(typeof sprites[0].bytes, 'string');
  assert.strictEqual(sprites[1].bytes, undefined);

  const sizes = { '/g/kl.sna': 49179, '/g/tiles.bin': 100 };
  const lost = m.addSnapshotPointers(sprites, { file: 'set.sna', size: 49179 }, (f) => sizes[f]);
  assert.deepStrictEqual(lost, []);
  assert.strictEqual(sprites[0].snapshot, undefined);
  assert.deepStrictEqual(sprites[1].snapshot, { file: 'set.sna', offset: 27 + 0x5000, address: 0x9000 });
  assert.deepStrictEqual(sprites[2].snapshot, { file: '/g/kl.sna', offset: 19237, address: 19237 - 27 + 0x4000 });
  assert.strictEqual(sprites[3].snapshot, undefined);

  // With nothing saved, a sprite from memory has nowhere to point.
  const again = JSON.parse(JSON.stringify(atlas)).meta.zx.sprites;
  assert.deepStrictEqual(m.addSnapshotPointers(again, null, (f) => sizes[f]), ['guard']);

  // And reading them back goes where they point.
  const disk = {
    'set.sna': Uint8Array.from({ length: 49179 }, (_, i) => (i === 27 + 0x5000 ? 7 : i === 27 + 0x5001 ? 8 : 0)),
    '/g/kl.sna': Uint8Array.from({ length: 49179 }, (_, i) => (i === 19237 ? 9 : 0)),
    '/g/tiles.bin': Uint8Array.from({ length: 100 }, (_, i) => (i === 5 ? 10 : 0))
  };
  const read = (f) => disk[f];
  assert.deepStrictEqual(Array.from(m.pointedBytes(sprites[1], read)), [7, 8]);
  assert.deepStrictEqual(Array.from(m.pointedBytes(sprites[2], read)), [9]);
  assert.deepStrictEqual(Array.from(m.pointedBytes(sprites[3], read)), [10]);
  assert.strictEqual(m.pointedBytes({ source: 'selection', length: 1 }, read), null);
});

test('a .sna maps addresses from $4000 straight through', () => {
  assert.strictEqual(m.snaOffsetOf(0x4000, 49179), 27);
  assert.strictEqual(m.snaOffsetOf(0xFFFF, 49179), 49178);
  assert.strictEqual(m.snaOffsetOf(0x3D00, 49179), null);   // the ROM is not in it
  assert.strictEqual(m.snaOffsetOf(0x8000, 1000), null);    // not a .sna
  assert.strictEqual(m.snaAddressOf(19237, 49179), 19237 - 27 + 0x4000);
  assert.strictEqual(m.snaAddressOf(10, 49179), null);      // the header
  assert.strictEqual(m.snaAddressOf(49179, 131103), null);  // a 128K's other pages
  assert.strictEqual(m.snaAddressOf(49178, 131103), 0xFFFF);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
