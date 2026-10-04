// Tests for behaviours.js: the behaviours an object template can be given,
// read out of a game's movers.s. Plain Node:
//
//   node examples/filmation/vscode/tests/behaviours_test.js

'use strict';

const assert = require('assert');
const path = require('path');
const b = require('../behaviours');

const FILMATION = path.resolve(__dirname, '..', '..');

let failures = 0;
let skipped = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    if (err && err.skip) { skipped++; console.log('skip ' + name + ': ' + err.message); return; }
    failures++;
    console.log('FAIL ' + name);
    console.log(err && err.stack ? err.stack : err);
  }
}

function skip(why) {
  const err = new Error(why);
  err.skip = true;
  throw err;
}

test('a behaviour is a MOVE_ name given a number; a name given a name is not', () => {
  const found = b.parseBehaviours([
    'MOVE_NONE\t\tEQU\t\t0',
    'MOVE_STILL\t\tEQU\t\t1\t\t; kills',
    'MOVE_BALL\t\tEQU\t\t2',
    'MOVE_HARMLESS\tEQU\t\t$03',
    'MOVE_CARRIED\tEQU\t\t3',
    'MOVE_LOOSE\t\tEQU\t\tMOVE_CARRIED',
    'STATE_RISING\tEQU\t\t4',
    'BEHAVIOUR_DEADLY\tEQU\tMOVE_STILL',
    'BEHAVIOUR_HARMLESS\tEQU\tMOVE_HARMLESS',
    'BEHAVIOUR_LOOSE\tEQU\t\tMOVE_LOOSE'
  ].join('\n'));
  assert.deepStrictEqual(found.list.map((x) => x.name),
                         ['MOVE_STILL', 'MOVE_BALL', 'MOVE_HARMLESS', 'MOVE_CARRIED']);
  // The bands, through however many names: LOOSE is CARRIED is 3.
  assert.strictEqual(found.loose, 3);
  const by = (name) => found.list.find((x) => x.name === name);
  assert.ok(by('MOVE_STILL').kills && by('MOVE_BALL').kills);
  assert.ok(!by('MOVE_CARRIED').kills && by('MOVE_CARRIED').loose);
  assert.ok(!by('MOVE_BALL').loose);
  assert.strictEqual(by('MOVE_CARRIED').label, 'carried');
});

test('lightkeep: its movers.s, as the templates editor will list it', () => {
  const found = b.behavioursOf(path.join(FILMATION, 'lightkeep'));
  if (!found) skip('lightkeep/movers.s is not here');
  const names = found.list.map((x) => x.name);
  for (const name of ['MOVE_STILL', 'MOVE_GUARD_U', 'MOVE_GATE', 'MOVE_SLIDE_U',
                      'MOVE_CARRIED', 'MOVE_PUSHED', 'MOVE_SLIDING']) {
    assert.ok(names.indexOf(name) >= 0, name + ' is offered');
  }
  // The band markers, given the behaviours they mark by name, are not.
  for (const name of ['MOVE_LOOSE', 'MOVE_HARMLESS', 'MOVE_CRUSHING', 'MOVE_MONSTER_LAST']) {
    assert.strictEqual(names.indexOf(name), -1, name + ' is not');
  }
  assert.strictEqual(found.loose, 17);
  const by = (name) => found.list.find((x) => x.name === name);
  assert.ok(by('MOVE_PUSHED').loose && !by('MOVE_GHOST').loose);
  assert.ok(by('MOVE_GUARD_U').kills && !by('MOVE_SLIDE_U').kills);
  assert.strictEqual(by('MOVE_SPIKE_BALL').label, 'spike ball');
  // In the order the game numbers them.
  const values = found.list.map((x) => x.value);
  assert.deepStrictEqual(values, values.slice().sort((p, q) => p - q));
});

test('a game with no movers.s has none', () => {
  assert.strictEqual(b.behavioursOf(path.join(FILMATION, 'no-such-game')), null);
});

if (failures) {
  console.log(failures + ' failed');
  process.exit(1);
}
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
