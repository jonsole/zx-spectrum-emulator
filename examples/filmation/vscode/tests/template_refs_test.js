// Which templates the games' own code depends on, read from the real sources.
//
//   node examples/filmation/vscode/tests/template_refs_test.js
//
// The templates panel warns before a rename breaks the build. This checks the
// warnings are the right ones: Knight Lore's movers.s gives particular object
// templates their behaviour by label, and room_build.s tests scenery labels.

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { codeReferences } = require('../template_refs');
const m = require('../room_model');

const FILMATION = path.join(__dirname, '..', '..');

let failures = 0;
let skipped = 0;
function test(name, body) {
  try {
    body();
    console.log('ok   ' + name);
  } catch (err) {
    if (err && err.skip) { skipped++; console.log('skip ' + name + ' -- ' + err.message); return; }
    failures++;
    console.log('FAIL ' + name);
    console.log(err.stack);
  }
}
function skip(why) { const err = new Error(why); err.skip = true; throw err; }

function atlasOf(game) {
  const read = (leaf) => fs.readFileSync(path.join(FILMATION, game, leaf), 'utf8');
  return m.withTemplates(m.parseAtlas(read('rooms.json')), m.parseTemplates(read('templates.json')));
}

function refsOf(game) {
  const here = path.join(FILMATION, game);
  if (!fs.existsSync(path.join(here, 'room_data.s'))) skip(game + '/room_data.s has not been built');
  return codeReferences(here);
}

// The template at a position, by name, so the checks read as names.
function named(atlas, group, refs) {
  const names = Object.keys(atlas[group]);
  const out = {};
  for (const at of Object.keys(refs[group])) out[names[at]] = refs[group][at];
  return out;
}

test('knightlore: the guards and the balls are behaviour movers.s gives by label', () => {
  const refs = refsOf('knightlore');
  const objects = named(atlasOf('knightlore'), 'objectTemplates', refs);
  for (const name of ['object_guard_ew', 'object_guard_square', 'object_ball_bounce']) {
    assert.ok(objects[name], name + ' should be referenced');
    assert.ok(objects[name].files.some((f) => /movers\.s$/.test(f)), name);
  }
  assert.strictEqual(objects.object_guard_ew.label, 'FG_GUARD_EW');
});

test('knightlore: room_build.s tests the gates and the high arches by label', () => {
  const refs = refsOf('knightlore');
  const scenery = named(atlasOf('knightlore'), 'sceneryTemplates', refs);
  for (const name of ['scenery_gate_0', 'scenery_gate_3', 'scenery_high_arch_e']) {
    assert.ok(scenery[name], name + ' should be referenced');
    assert.ok(scenery[name].files.some((f) => /room_build\.s$/.test(f)), name);
  }
});

test('knightlore: an ordinary block is referenced by nothing', () => {
  const refs = refsOf('knightlore');
  const objects = named(atlasOf('knightlore'), 'objectTemplates', refs);
  assert.strictEqual(objects.object_block, undefined);
});

test('the generated sources are not counted as references', () => {
  // room_data.s defines every label; if it counted, everything would be "used".
  const refs = refsOf('knightlore');
  for (const group of ['sceneryTemplates', 'objectTemplates']) {
    for (const at of Object.keys(refs[group])) {
      for (const file of refs[group][at].files) {
        assert.ok(!/room_data\.s$/.test(file), file);
      }
    }
  }
});

test('pentagram: object labels are matched by position, not by their value', () => {
  // Pentagram's OBJ_ EQUs are byte offsets into its table, twice the position.
  // Whatever it finds has to land on a real template.
  const refs = refsOf('pentagram');
  const atlas = atlasOf('pentagram');
  const count = Object.keys(atlas.objectTemplates).length;
  for (const at of Object.keys(refs.objectTemplates)) {
    assert.ok(Number(at) < count, 'position ' + at + ' is past the table');
  }
});

if (failures) { console.log(failures + ' failed'); process.exit(1); }
console.log('all passed' + (skipped ? ' (' + skipped + ' skipped)' : ''));
