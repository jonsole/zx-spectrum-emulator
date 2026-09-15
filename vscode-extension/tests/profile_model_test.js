// Tests for profile_model.js -- how the emulator's profile report becomes the
// editor's heat map. Plain Node, no vscode API:
//
//   node vscode-extension/tests/profile_model_test.js

const assert = require('assert');
const path = require('path');
const { heatLevel, indexReport, reportKeyFor, lineLabel, lineHover, HEAT_LEVELS } = require('../profile_model');

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

const SPRITE = path.resolve('/proj/examples/filmation/sprite.s');
const OBJECT = path.resolve('/proj/examples/filmation/object.s');

// Two frames of a made-up game: sprite_blit's inner loop is most of it.
const REPORT = {
  active: false,
  frames: 2,
  tstates: 100000,
  interrupt_tstates: 26,
  unmapped_tstates: 1000,
  lines: [
    { path: SPRITE, line: 212, hits: 4000, tstates: 40000, symbol: 'sprite_blit.row+3' },
    { path: SPRITE, line: 164, hits: 20, tstates: 300, symbol: 'sprite_blit' },
    { path: OBJECT, line: 50, hits: 10, tstates: 90, symbol: 'object_update+2' },
  ],
  routines: [
    { name: 'sprite_blit', path: SPRITE, line: 164, hits: 4100, tstates: 45000 },
    { name: '$9000-$90FF', hits: 5, tstates: 1000 },
  ],
};

test('heat levels climb with share, and a trickle is not coloured', () => {
  assert.strictEqual(heatLevel(0), 0);
  assert.strictEqual(heatLevel(0.0005), 0);
  assert.strictEqual(heatLevel(0.001), 1);
  assert.strictEqual(heatLevel(0.03), 4);
  assert.strictEqual(heatLevel(0.4), HEAT_LEVELS);
});

test('a report is indexed by file and line, with each line\'s share', () => {
  const model = indexReport(REPORT);
  const key = reportKeyFor(model, SPRITE);
  assert.ok(key !== undefined);
  const hot = model.byFile.get(key).get(212);
  assert.strictEqual(hot.share, 0.4);
  assert.strictEqual(model.routinesByFile.get(key).get(164).name, 'sprite_blit');
  // A routine with no source is listed but has no line to sit on.
  assert.strictEqual(model.routines.length, 2);
});

test('a file the report spells differently is found by its name', () => {
  const model = indexReport(REPORT);
  assert.ok(reportKeyFor(model, path.resolve('/elsewhere/checkout/object.s')) !== undefined);
  assert.strictEqual(reportKeyFor(model, path.resolve('/proj/room.s')), undefined);
});

test('two report files with one name are not guessed between', () => {
  const report = JSON.parse(JSON.stringify(REPORT));
  report.lines.push({ path: path.resolve('/proj/other/object.s'), line: 1, hits: 1, tstates: 1, symbol: '' });
  const model = indexReport(report);
  assert.strictEqual(reportKeyFor(model, path.resolve('/elsewhere/object.s')), undefined);
  assert.ok(reportKeyFor(model, OBJECT) !== undefined);
});

test('labels read per frame, and cool lines get none', () => {
  const model = indexReport(REPORT);
  const key = reportKeyFor(model, SPRITE);
  const hot = lineLabel(model, model.byFile.get(key).get(212), undefined);
  assert.strictEqual(hot, '40% · 20,000 T/frame · 2,000×/frame');
  // 0.09% of the time: coloured faintly at most, never labelled.
  const objectKey = reportKeyFor(model, OBJECT);
  assert.strictEqual(lineLabel(model, model.byFile.get(objectKey).get(50), undefined), undefined);
  // The label line leads with its routine's total.
  const label = lineLabel(model, model.byFile.get(key).get(164), model.routinesByFile.get(key).get(164));
  assert.ok(label.startsWith('sprite_blit 45% · 22,500 T/frame'), label);
});

test('a profile that was only stepped reads in totals', () => {
  const report = JSON.parse(JSON.stringify(REPORT));
  report.frames = 0;
  const model = indexReport(report);
  const key = reportKeyFor(model, SPRITE);
  assert.strictEqual(lineLabel(model, model.byFile.get(key).get(212), undefined), '40% · 40,000 T · 4,000×');
});

test('the hover has the exact numbers', () => {
  const model = indexReport(REPORT);
  const key = reportKeyFor(model, SPRITE);
  const text = lineHover(model, model.byFile.get(key).get(212), undefined);
  assert.ok(text.includes('40,000 T-states over 4,000 runs, 10.0 T a run'), text);
  assert.ok(text.includes('sprite_blit.row+3'), text);
});

// ---- the call tree ----

const { rootGroups, childGroups, groupDescription } = require('../profile_model');

function node(id, parent, name, calls, self, total, extra) {
  return Object.assign({ id, parent, name, calls, self_tstates: self, tstates: total, addr: 0, interrupt: false }, extra || {});
}

// main calls draw and blit; draw calls blit too, and is interrupted.
//   0 root              self 10   total 200
//   1   main            self 20   total 190
//   2     draw  x5      self 40   total 120
//   3       blit x50    self 60   total 60
//   6       irq         self 20   total 20   (interrupt)
//   4     blit  x10     self 50   total 50
const TREE_REPORT = {
  frames: 0,
  tstates: 200,
  call_nodes: [
    node(0, null, '(outside any call)', 0, 10, 200),
    node(1, 0, 'main', 1, 20, 190, { path: SPRITE, line: 1 }),
    node(2, 1, 'draw', 5, 40, 120, { path: SPRITE, line: 20 }),
    node(3, 2, 'blit', 50, 60, 60, { path: SPRITE, line: 40 }),
    node(4, 1, 'blit', 10, 50, 50, { path: SPRITE, line: 40 }),
    node(5, 2, 'irq', 3, 20, 20, { interrupt: true }),
  ],
};

function summary(groups) {
  return groups.map((g) => `${g.name}=${g.total}`).join(' ');
}

test('the top level has every routine, however it was reached', () => {
  const model = indexReport(TREE_REPORT);
  const roots = rootGroups(model.callTree, 'total');
  assert.strictEqual(summary(roots), 'main=190 draw=120 blit=110 irq=20 (outside any call)=10');
  const blit = roots.find((g) => g.name === 'blit');
  assert.strictEqual(blit.calls, 60);
  assert.strictEqual(blit.nodes.length, 2);
  // By own code instead: blit's 110 is all its own.
  assert.strictEqual(rootGroups(model.callTree, 'self')[0].name, 'blit');
});

test('expanding a routine shows what its calls cost it, and its own code', () => {
  const model = indexReport(TREE_REPORT);
  const roots = rootGroups(model.callTree, 'total');
  const draw = roots.find((g) => g.name === 'draw');
  assert.strictEqual(summary(childGroups(model.callTree, draw, 'total')), 'blit=60 (own code)=40 irq=20');
  const main = roots.find((g) => g.name === 'main');
  const kids = childGroups(model.callTree, main, 'total');
  assert.strictEqual(summary(kids), 'draw=120 blit=50 (own code)=20');
  // Deeper: main > draw > blit, only the calls made from that path.
  const drawUnderMain = kids[0];
  assert.strictEqual(summary(childGroups(model.callTree, drawUnderMain, 'total')), 'blit=60 (own code)=40 irq=20');
  // Ids are paths, so an expanded row keeps its place across refreshes.
  assert.strictEqual(drawUnderMain.id, 'call:main/call:draw');
  // A leaf has nothing to expand into, not even its own code.
  const blitUnderDraw = childGroups(model.callTree, drawUnderMain, 'total')[0];
  assert.strictEqual(blitUnderDraw.hasChildren, false);
  assert.strictEqual(childGroups(model.callTree, blitUnderDraw, 'total').length, 0);
});

test('a recursive routine is counted once, from its outermost call', () => {
  const model = indexReport({
    frames: 0,
    tstates: 30,
    call_nodes: [
      node(0, null, '(outside any call)', 0, 0, 30),
      node(1, 0, 'fact', 1, 10, 30),
      node(2, 1, 'fact', 1, 10, 20),
      node(3, 2, 'fact', 1, 10, 10),
    ],
  });
  const roots = rootGroups(model.callTree, 'total');
  assert.strictEqual(summary(roots), 'fact=30');
  assert.strictEqual(summary(childGroups(model.callTree, roots[0], 'total')), 'fact=20 (own code)=10');
});

test('a group reads as share, cost and calls', () => {
  const model = indexReport(Object.assign({}, TREE_REPORT, { frames: 2 }));
  const draw = rootGroups(model.callTree, 'total').find((g) => g.name === 'draw');
  assert.strictEqual(groupDescription(model, draw, 'total'), '60% · 60.0 T/frame · 2.50 calls/frame');
  assert.strictEqual(groupDescription(model, draw, 'self'), 'own 20% · 20.0 T/frame · total 60% · 2.50 calls/frame');
});

if (failures > 0) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed');
