// Tests for asm_doc.js -- the comment above a routine, and the register
// contract (In, Out, Corrupts) the hover shows first. Plain Node, no vscode
// API and no test framework:
//
//   node vscode-extension/tests/asm_doc_test.js
//
// The last test reads the Filmation engine and both games, so a header style
// the parser does not know shows up here and not only in a hover.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { commentAbove, parseContract, hasContract, contractMarkdown } = require('../asm_doc');

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

/// A header as source lines, and the contract parsed from above its last line.
function parse(source) {
  const lines = source.split('\n');
  return parseContract(commentAbove(lines, lines.length - 1, 24));
}

test('the three labelled lines, with continuations and a second register', () => {
  const c = parse([
    '; Step an object.',
    ';',
    '; In:  IX -> the object',
    ';      A  = the step in Z, which may be',
    ';           negative',
    '; Out: DE -> the NEXT field that named us',
    ';      Z set if it did not move',
    '; Corrupts: F, BC, HL',
    'depth_step:  ld a,b',
  ].join('\n'));
  assert.deepStrictEqual(c.inputs, [
    { reg: 'IX', op: '->', text: 'the object' },
    { reg: 'A', op: '=', text: 'the step in Z, which may be negative' },
  ]);
  assert.deepStrictEqual(c.outputs, [
    { reg: 'DE', op: '->', text: 'the NEXT field that named us' },
    { reg: '', op: '', text: 'Z set if it did not move' },
  ]);
  assert.strictEqual(c.corrupts, 'F, BC, HL');
  assert.deepStrictEqual(c.prose, ['Step an object.']);
});

test('"nothing" is an entry, so a missing line stays distinguishable', () => {
  const c = parse('; In: nothing\n; Out: nothing\n; Corrupts: AF\nf: ret');
  assert.deepStrictEqual(c.inputs, [{ reg: '', op: '', text: 'nothing' }]);
  assert.deepStrictEqual(c.outputs, [{ reg: '', op: '', text: 'nothing' }]);
  assert.strictEqual(c.corrupts, 'AF');
});

test('older headers: unlabelled register lines, and Corrupts as a sentence', () => {
  // depth_unlink's, as it was written.
  const c = parse([
    '; Take an object out of the list.',
    ';',
    '; A NEXT field never ends a page.',
    ';   IX -> the object',
    '; Out: DE -> the NEXT field that named us',
    '; Corrupts F, BC, HL. A is kept.',
    '\t\t\t\t\tASSERT\t(object_list & $FF) != $FF',
    'depth_unlink:\t\tld\t\tl,(ix+OBJ.PREV)',
  ].join('\n'));
  assert.deepStrictEqual(c.inputs, [{ reg: 'IX', op: '->', text: 'the object' }]);
  assert.deepStrictEqual(c.outputs, [{ reg: 'DE', op: '->', text: 'the NEXT field that named us' }]);
  assert.strictEqual(c.corrupts, 'F, BC, HL. A is kept.');
  assert.deepStrictEqual(c.prose, ['Take an object out of the list.', '', 'A NEXT field never ends a page.']);
});

test('a register pair and a dash are an input; the dash reads as =', () => {
  const c = parse(';   B, C - the half-period\n;   HL   - how many cycles\n; Corrupts AF, HL.\nsound_long: ld a,b');
  assert.deepStrictEqual(c.inputs, [
    { reg: 'B, C', op: '=', text: 'the half-period' },
    { reg: 'HL', op: '=', text: 'how many cycles' },
  ]);
});

test('a variable in memory joins an open list, but does not open one', () => {
  const c = parse([
    ';   HL -> the delta to cut',
    ';   collide_mask - the bit to set',
    '; Corrupts AF.',
    'object_clamp: ld a,(hl)',
  ].join('\n'));
  assert.deepStrictEqual(c.inputs.map((e) => e.reg), ['HL', 'collide_mask']);

  const prose = parse(';   the object - which is to say\n; Corrupts AF.\nf: ret');
  assert.deepStrictEqual(prose.inputs, []);
  assert.deepStrictEqual(prose.prose, ['  the object - which is to say']);
});

test('Corrupts and Preserves tacked onto an Out line are split off', () => {
  const c = parse('; Out: zf set if he is. Corrupts AF, C.\nf: ret');
  assert.deepStrictEqual(c.outputs, [{ reg: '', op: '', text: 'zf set if he is.' }]);
  assert.strictEqual(c.corrupts, 'AF, C.');

  const p = parse('; Out: A - the behaviour. Preserves DE.\nf: ret');
  assert.deepStrictEqual(p.outputs, [{ reg: 'A', op: '=', text: 'the behaviour.' }]);
  assert.strictEqual(p.preserves, 'DE.');
});

test('an Out that runs on unindented is continued until its sentence ends', () => {
  const c = parse([
    '; Out: carry set and B, C the half period; carry clear for a note',
    '; the tunes never play, which is then skipped.',
    '; Corrupts AF, D, HL.',
    'tune_note_at: ld hl,0',
  ].join('\n'));
  assert.strictEqual(c.outputs.length, 1);
  assert.strictEqual(c.outputs[0].text,
    'carry set and B, C the half period; carry clear for a note the tunes never play, which is then skipped.');
  assert.deepStrictEqual(c.prose, []);
});

test('prose after the contract stays prose', () => {
  const c = parse([
    '; Add a step.',
    ';   IX -> the object',
    '; Out: Z set if the step was zero',
    '; Corrupts AF, C.',
    ';',
    '; The step is ORed together first.',
    'depth_add_step: or d',
  ].join('\n'));
  assert.strictEqual(c.corrupts, 'AF, C.');
  assert.deepStrictEqual(c.prose, ['Add a step.', '', 'The step is ORed together first.']);
});

test('Entry and Exit are In and Out; "In the pool" is not', () => {
  const c = parse('; Entry:  B = screen row\n;         C = screen column\n; Exit:   HL = screen byte address\nrow: ld a,b');
  assert.deepStrictEqual(c.inputs.map((e) => e.reg), ['B', 'C']);
  assert.deepStrictEqual(c.outputs.map((e) => e.reg), ['HL']);

  const prose = parse('; In the pool, the room comes first.\nf: ret');
  assert.ok(!hasContract(prose));
  assert.deepStrictEqual(prose.prose, ['In the pool, the room comes first.']);
});

test('a comment with no contract is all prose, and draws no table', () => {
  const c = parse('; Just a note.\n;\n; And another.\nf: ret');
  assert.ok(!hasContract(c));
  assert.strictEqual(contractMarkdown(c), '');
  assert.deepStrictEqual(c.prose, ['Just a note.', '', 'And another.']);
});

test('commentAbove steps over IFUSED and ALIGN, stops at code, and drops rules', () => {
  const lines = [
    '\tret',
    '; ------------',
    '; Find one.',
    '; Corrupts AF.',
    '\t\t\tIFUSED\tmover_find',
    '\t\t\tALIGN\t2',
    'mover_find: ld a,b',
  ];
  assert.deepStrictEqual(commentAbove(lines, 6, 24), ['Find one.', 'Corrupts AF.']);
  // The limit counts up from the label, so it is the top that is cut.
  assert.deepStrictEqual(commentAbove(lines, 6, 1), ['Corrupts AF.']);
});

test('the table: a row an entry, the section named once, registers as code', () => {
  const md = contractMarkdown(parse('; In:  IX -> the object\n;      A = the step\n; Corrupts: F, BC\nf: ret'));
  assert.strictEqual(md, [
    '| | |',
    '|:--|:--|',
    '| **In** | `IX` &rarr; the object |',
    '|  | `A` = the step |',
    '| **Corrupts** | F, BC |',
    '',
  ].join('\n'));
});

test('the Filmation sources: every header that says Out or Corrupts is read as a contract', () => {
  const root = path.resolve(__dirname, '../../examples/filmation');
  let headers = 0;
  const missed = [];
  for (const dir of ['engine', 'knightlore', 'pentagram']) {
    for (const name of fs.readdirSync(path.join(root, dir))) {
      if (!name.endsWith('.s')) {
        continue;
      }
      const lines = fs.readFileSync(path.join(root, dir, name), 'utf8').split(/\r?\n/);
      lines.forEach((line, i) => {
        if (!/^[A-Za-z_]\w*:?\s/.test(line) && !/^\s+MACRO\s/.test(line)) {
          return;
        }
        const comment = commentAbove(lines, i, 24);
        if (!comment.some((text) => /^(Out:|Corrupts)/.test(text.trim()))) {
          return;
        }
        headers++;
        const c = parseContract(comment);
        // Whatever says Out or Corrupts must have been taken out of the prose.
        if (!hasContract(c) || c.prose.some((text) => /^(Out:|Corrupts)/.test(text.trim()))) {
          missed.push(dir + '/' + name + ':' + (i + 1));
        }
      });
    }
  }
  assert.ok(headers > 100, 'only ' + headers + ' headers found');
  assert.deepStrictEqual(missed, []);
});

if (failures > 0) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
