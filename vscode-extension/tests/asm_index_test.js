// Tests for asm_index.js -- the parser and resolver behind Go to Definition
// and Find All References. Plain Node, no vscode API and no test framework:
//
//   node vscode-extension/tests/asm_index_test.js
//
// (No node on the path? VS Code's own will do:
//   ELECTRON_RUN_AS_NODE=1 "<VS Code>/Code.exe" vscode-extension/tests/asm_index_test.js)
//
// The last test indexes the real sources in this repo, so a change that
// breaks resolution on them shows up here and not only in the editor.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { AsmIndex, parseAsm, scanLine } = require('../asm_index');

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

/// The position of the `nth` occurrence of `needle` on the line containing
/// `lineNeedle`, as [line, col] -- so tests point at text, not at numbers.
function at(text, lineNeedle, needle, nth) {
  const lines = text.split('\n');
  for (let line = 0; line < lines.length; line++) {
    if (lines[line].includes(lineNeedle)) {
      let col = -1;
      for (let k = 0; k <= (nth || 0); k++) {
        col = lines[line].indexOf(needle, col + 1);
      }
      assert.ok(col >= 0, needle + ' not on line ' + line);
      return [line, col];
    }
  }
  throw new Error('no line contains ' + lineNeedle);
}

function defNames(parsed) {
  const names = [];
  for (const def of parsed.defs) {
    names.push(def.kind + ':' + def.name);
  }
  return names;
}

const MAIN = [
  '\t\t\tDEVICE ZXSPECTRUM48',
  'SCREEN\t\tEQU\t$4000',
  '  ATTRS = $5800',
  '\t\t\tSTRUCT OBJ',
  'NEXT:\t\tDS 2',
  'FLAGS:\t\tDS 1',
  '\t\t\tENDS',
  '\t\t\tMACRO\tclear_flag flags, mask',
  '\t\t\tld a,(ix+OBJ.FLAGS)',
  '\t\t\tand ~mask',
  '\t\t\tjr z,.done',
  '.done:\t\tld (ix+OBJ.FLAGS),a',
  '\t\t\tENDM',
  '\t\t\tINCLUDE "sub.s"',
  'start:\t\tld hl,SCREEN',
  '\t\t\tcall blit',
  '.loop:\t\tdjnz .loop',
  '\t\t\tjp start.loop ; start.loop is .loop',
  '\t\t\tex af,af\'',
  '\t\t\tld a,\'x\'',
  '\t\t\tld a,0FFh',
  '\t\t\tclear_flag 0, $80',
  '/* blit is',
  '   not here */',
  'other\t\tret',
  '.loop\t\tjr .loop',
].join('\n');

const SUB = [
  'blit:\t\tld de,ATTRS',
  '.loop:\t\tldir',
  '\t\t\tret',
].join('\n');

test('scanLine skips comments, numbers, strings and the shadow register', () => {
  const scan = scanLine("  ld a,0FFh ; SCREEN", false);
  assert.deepStrictEqual(scan.words.map((w) => w.text), ['ld', 'a']);
  const ex = scanLine("  ex af,af' ; don't", false);
  assert.deepStrictEqual(ex.words.map((w) => w.text), ['ex', 'af', 'af']);
  const hex = scanLine('  ld a,#1F + $FF + %1010', false);
  assert.deepStrictEqual(hex.words.map((w) => w.text), ['ld', 'a']);
  const str = scanLine('  INCLUDE "a b.s"', false);
  assert.strictEqual(str.strings[0].text, 'a b.s');
  const block = scanLine('  ld a,b /* x', false);
  assert.strictEqual(block.inBlockComment, true);
  assert.strictEqual(scanLine('  y */ ld c,d', true).words[0].text, 'ld');
});

test('parseAsm names every kind of definition the sjasmplus way', () => {
  const parsed = parseAsm(MAIN);
  assert.deepStrictEqual(defNames(parsed), [
    'constant:SCREEN',
    'constant:ATTRS',
    'struct:OBJ',
    'field:OBJ.NEXT',
    'field:OBJ.FLAGS',
    'macro:clear_flag',
    'param:clear_flag(flags)',
    'param:clear_flag(mask)',
    'local:clear_flag.done',
    'label:start',
    'local:start.loop',
    'label:other',
    'local:other.loop',
  ]);
  assert.deepStrictEqual(parsed.includes.map((i) => i.target), ['sub.s']);
});

function buildIndex() {
  const index = new AsmIndex();
  index.update('/proj/main.s', MAIN);
  index.update('/proj/sub.s', SUB);
  // An unrelated program with its own start and blit.
  index.update('/other/game.asm', 'start: jp blit\nblit: ret\n');
  return index;
}

test('a local label resolves to the one under its own parent', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'djnz .loop', '.loop');
  const found = index.definitionsAt('/proj/main.s', line, col);
  assert.strictEqual(found.name, 'start.loop');
  assert.strictEqual(found.results.length, 1);
  assert.strictEqual(found.results[0].def.line, at(MAIN, '.loop:', '.loop')[0]);

  const [line2, col2] = at(MAIN, 'jr .loop', '.loop');
  assert.strictEqual(index.definitionsAt('/proj/main.s', line2, col2).name, 'other.loop');
});

test('a dotted name goes to whichever part was clicked', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'ld a,(ix+OBJ.FLAGS)', 'OBJ');
  assert.strictEqual(index.definitionsAt('/proj/main.s', line, col).name, 'OBJ');
  const [, fieldCol] = at(MAIN, 'ld a,(ix+OBJ.FLAGS)', 'FLAGS');
  assert.strictEqual(index.definitionsAt('/proj/main.s', line, fieldCol).name, 'OBJ.FLAGS');
  const [jpLine, jpCol] = at(MAIN, 'jp start.loop', 'loop');
  assert.strictEqual(index.definitionsAt('/proj/main.s', jpLine, jpCol).name, 'start.loop');
  // The leading dot of a local is part of the local, not a click on its parent.
  const [dLine, dCol] = at(MAIN, 'djnz .loop', '.loop');
  assert.strictEqual(index.definitionsAt('/proj/main.s', dLine, dCol).name, 'start.loop');
});

test('a macro parameter resolves to the macro line, and only inside the macro', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'and ~mask', 'mask');
  const found = index.definitionsAt('/proj/main.s', line, col);
  assert.strictEqual(found.name, 'clear_flag(mask)');
  assert.strictEqual(found.results[0].def.line, at(MAIN, 'MACRO', 'mask')[0]);
  const [useLine, useCol] = at(MAIN, 'clear_flag 0', 'clear_flag');
  assert.strictEqual(index.definitionsAt('/proj/main.s', useLine, useCol).name, 'clear_flag');
});

test('a name defined in an included file is found there, not in another program', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'call blit', 'blit');
  const found = index.definitionsAt('/proj/main.s', line, col);
  assert.strictEqual(found.results.length, 1);
  assert.strictEqual(path.normalize(found.results[0].path), path.normalize('/proj/sub.s'));
  // ...and the other way: sub.s sees main.s's constant through the include.
  const subFound = index.definitionsAt('/proj/sub.s', 0, SUB.indexOf('ATTRS'));
  assert.strictEqual(subFound.results.length, 1);
  assert.strictEqual(subFound.results[0].def.name, 'ATTRS');
});

test('references stay inside the program and can leave out the declaration', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'call blit', 'blit');
  const withDecl = index.referencesAt('/proj/main.s', line, col, true);
  assert.strictEqual(withDecl.length, 2); // the call and blit: in sub.s -- not game.asm
  const withoutDecl = index.referencesAt('/proj/main.s', line, col, false);
  assert.strictEqual(withoutDecl.length, 1);

  const [lLine, lCol] = at(MAIN, 'djnz .loop', '.loop');
  const loops = index.referencesAt('/proj/main.s', lLine, lCol, true);
  // .loop: definition, djnz .loop, jp start.loop -- and not other's .loop or blit's.
  assert.strictEqual(loops.length, 3);
});

test('a label named like a directive is still referenced', () => {
  const text = 'CHARSET:\n  DEFB 0\n  LD HL,CHARSET\n  CHARSET "x"\n';
  const index = new AsmIndex();
  index.update('/rom/rom.asm', text);
  const [line, col] = at(text, 'LD HL,CHARSET', 'CHARSET');
  // The definition and the LD -- not the directive in the directive's place.
  assert.strictEqual(index.referencesAt('/rom/rom.asm', line, col, true).length, 2);
});

test('comments and block comments hide names', () => {
  const index = buildIndex();
  const [line] = at(MAIN, '/* blit is', 'blit');
  assert.strictEqual(index.tokenAt('/proj/main.s', line, 3), undefined);
  const [cLine, cCol] = at(MAIN, '; start.loop is', 'start.loop', 1);
  assert.strictEqual(index.tokenAt('/proj/main.s', cLine, cCol), undefined);
});

test('an edit replaces a file\'s definitions', () => {
  const index = buildIndex();
  index.update('/proj/sub.s', 'blat: ret\n');
  assert.strictEqual(index.byName.has('blit'), true); // game.asm still has one
  assert.strictEqual(index.definitionsOf('blit', '/proj/main.s')[0].path, '/other/game.asm');
  index.remove('/other/game.asm');
  assert.strictEqual(index.byName.has('blit'), false);
});

/// `text` with rename edits for `file` applied, right to left so the columns
/// of the ones still to come stay put.
function applyEdits(text, edits, file) {
  const lines = text.split('\n');
  const mine = edits.filter((e) => e.path === file).sort((p, q) => q.line - p.line || q.col - p.col);
  for (const e of mine) {
    const l = lines[e.line];
    lines[e.line] = l.slice(0, e.col) + e.text + l.slice(e.col + e.len);
  }
  return lines.join('\n');
}

function renamed(file, text, lineNeedle, needle, newName, nth) {
  const index = buildIndex();
  const [line, col] = at(text, lineNeedle, needle, nth);
  const result = index.renameEdits(file, line, col, newName);
  assert.strictEqual(result.error, undefined, result.error);
  return result.edits;
}

test('renaming a local changes it where it is written, and nowhere else', () => {
  const edits = renamed('/proj/main.s', MAIN, 'djnz .loop', '.loop', 'again');
  const after = applyEdits(MAIN, edits, '/proj/main.s');
  assert.ok(after.includes('.again:\t\tdjnz .again'));
  assert.ok(after.includes('jp start.again ; start.loop is .loop'));
  // other's own .loop is a different label.
  assert.ok(after.includes('other\t\tret\n.loop\t\tjr .loop'));
  assert.strictEqual(edits.length, 3);
  // Typing the dot is the same as not.
  assert.strictEqual(renamed('/proj/main.s', MAIN, 'djnz .loop', '.loop', '.again').length, 3);
});

test('renaming a parent renames its dotted uses but leaves its .locals alone', () => {
  const edits = renamed('/proj/main.s', MAIN, 'start:', 'start', 'begin');
  const after = applyEdits(MAIN, edits, '/proj/main.s');
  assert.ok(after.includes('begin:\t\tld hl,SCREEN'));
  assert.ok(after.includes('jp begin.loop'));
  assert.ok(after.includes('.loop:\t\tdjnz .loop'));
  assert.strictEqual(edits.length, 2);
});

test('renaming a struct or a field renames that part of OBJ.FLAGS', () => {
  let after = applyEdits(MAIN, renamed('/proj/main.s', MAIN, 'ld a,(ix+OBJ.FLAGS)', 'FLAGS', 'BITS'), '/proj/main.s');
  assert.ok(after.includes('BITS:\t\tDS 1'));
  assert.ok(after.includes('ld a,(ix+OBJ.BITS)'));
  assert.ok(after.includes('ld (ix+OBJ.BITS),a'));
  after = applyEdits(MAIN, renamed('/proj/main.s', MAIN, 'ld a,(ix+OBJ.FLAGS)', 'OBJ', 'THING'), '/proj/main.s');
  assert.ok(after.includes('STRUCT THING'));
  assert.ok(after.includes('ld a,(ix+THING.FLAGS)'));
  assert.ok(after.includes('ld (ix+THING.FLAGS),a'));
});

test('renaming a macro parameter stays inside the macro', () => {
  const edits = renamed('/proj/main.s', MAIN, 'and ~mask', 'mask', 'bits');
  const after = applyEdits(MAIN, edits, '/proj/main.s');
  assert.ok(after.includes('clear_flag flags, bits'));
  assert.ok(after.includes('and ~bits'));
  assert.strictEqual(edits.length, 2);
});

test('renaming reaches the included file and not the other program', () => {
  const edits = renamed('/proj/main.s', MAIN, 'call blit', 'blit', 'draw');
  assert.strictEqual(edits.length, 2);
  assert.ok(applyEdits(SUB, edits, '/proj/sub.s').startsWith('draw:'));
  assert.ok(applyEdits(MAIN, edits, '/proj/main.s').includes('call draw'));
  for (const e of edits) {
    assert.notStrictEqual(e.path, '/other/game.asm');
  }
});

test('a rename that would clash, or is not a name, is refused', () => {
  const index = buildIndex();
  const [line, col] = at(MAIN, 'call blit', 'blit');
  assert.ok(/already defined/.test(index.renameEdits('/proj/main.s', line, col, 'start').error));
  assert.ok(/reserved/.test(index.renameEdits('/proj/main.s', line, col, 'LD').error));
  assert.ok(/not a name/.test(index.renameEdits('/proj/main.s', line, col, 'a.b').error));
  assert.ok(/not a name/.test(index.renameEdits('/proj/main.s', line, col, '9lives').error));
  const [cLine, cCol] = at(MAIN, 'DEVICE', 'ZXSPECTRUM48');
  assert.ok(/not defined/.test(index.renameTargetAt('/proj/main.s', cLine, cCol).error));
});

function callNames(groups, field) {
  return groups.map((g) => g[field].def.name + '@' + g.ranges.map((r) => r.line).join(','));
}

test('incoming calls are grouped under the routine each call is in', () => {
  const index = buildIndex();
  const blit = index.callItemAt('/proj/sub.s', 0, 1);
  assert.strictEqual(blit.def.name, 'blit');
  const [callLine] = at(MAIN, 'call blit', 'blit');
  assert.deepStrictEqual(callNames(index.incomingCalls(blit), 'caller'), ['start@' + callLine]);

  const [macroLine] = at(MAIN, 'clear_flag 0', 'clear_flag');
  const macro = index.callItemAt('/proj/main.s', macroLine, 5);
  assert.strictEqual(macro.def.name, 'clear_flag');
  assert.deepStrictEqual(callNames(index.incomingCalls(macro), 'caller'), ['start@' + macroLine]);
});

test('outgoing calls leave out jumps inside the routine itself', () => {
  const index = buildIndex();
  const [startLine] = at(MAIN, 'start:', 'start');
  const start = index.callItemAt('/proj/main.s', startLine, 0);
  const [callLine] = at(MAIN, 'call blit', 'blit');
  const [macroLine] = at(MAIN, 'clear_flag 0', 'clear_flag');
  // Not djnz .loop or jp start.loop: those are start's own.
  assert.deepStrictEqual(callNames(index.outgoingCalls(start), 'target'), ['blit@' + callLine, 'clear_flag@' + macroLine]);
  // The cursor anywhere inside a routine starts from that routine.
  assert.strictEqual(index.callItemAt('/proj/main.s', callLine, 3).def.name, 'start');
});

test('the repo\'s own sources resolve', () => {
  const root = path.resolve(__dirname, '..', '..');
  const index = new AsmIndex();
  const film = path.join(root, 'examples', 'filmation');
  const rom = path.join(root, 'rom_disassembly', 'rom.asm');
  if (!fs.existsSync(film) || !fs.existsSync(rom)) {
    console.log('     (skipped: sources not present)');
    return;
  }
  for (const name of fs.readdirSync(film)) {
    if (name.endsWith('.s')) {
      index.updateFromDisk(path.join(film, name));
    }
  }
  const started = Date.now();
  index.updateFromDisk(rom);
  const romMs = Date.now() - started;

  // The ROM: a label used long before it is defined.
  const romText = fs.readFileSync(rom, 'utf8');
  const [line, col] = at(romText, 'CALL SKIP_OVER', 'SKIP_OVER');
  const found = index.definitionsAt(rom, line, col);
  assert.strictEqual(found.results.length, 1);
  assert.ok(/^SKIP_OVER:/.test(romText.split('\n')[found.results[0].def.line]));
  assert.strictEqual(index.referencesAt(rom, line, col, false).length, 1);
  // ...and a system variable, whose every use should be found.
  const [cLine, cCol] = at(romText, 'LD HL,(CH_ADD)', 'CH_ADD');
  const expected = romText.split('\n').filter((l) => /\bCH_ADD\b/.test(l.split(';')[0])).length;
  assert.strictEqual(index.referencesAt(rom, cLine, cCol, true).length, expected);

  // filmation: a struct field used from a file that only includes the struct.
  const objectText = fs.readFileSync(path.join(film, 'object.s'), 'utf8');
  const [oLine, oCol] = at(objectText, '(ix+OBJ.FLAGS)', 'FLAGS');
  const field = index.definitionsAt(path.join(film, 'object.s'), oLine, oCol);
  assert.strictEqual(field.name, 'OBJ.FLAGS');
  assert.strictEqual(path.basename(field.results[0].path), 'object_struct.s');

  // The ROM's call graph: SKIP_OVER is called from TEST_CHAR, an entry point
  // inside GET_CHAR, and TEST_CHAR calls it.
  const skip = index.callItemAt(rom, found.results[0].def.line, 0);
  const incoming = index.incomingCalls(skip);
  assert.deepStrictEqual(incoming.map((g) => g.caller.def.name), ['TEST_CHAR']);
  const outgoing = index.outgoingCalls(incoming[0].caller);
  assert.ok(outgoing.some((g) => g.target.def.name === 'SKIP_OVER'));
  console.log('     (rom.asm parsed in ' + romMs + ' ms)');
});

if (failures > 0) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
